"""原生 RichEdit 控件：用 Windows TSF 输入，显示现代候选窗。

Tk 的 Text / Entry 在 Windows 上走 IMM32，微软拼音会画出旧式白色候选框。
RichEdit 4.1（msftedit.dll 的 ``RichEdit50W``）默认接入 TSF，候选窗与记事本、
浏览器一致。这个模块把 RichEdit 包成一个 Tk Frame，并提供应用需要的少量
Text 兼容方法（get / insert / delete / set_text / 撤销 / 滚动等）。
"""

from __future__ import annotations

import ctypes
import logging
import time
import tkinter as tk
from ctypes import wintypes
from typing import Callable

LOG = logging.getLogger(__name__)

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

try:  # RichEdit 4.1（Windows Vista+ 自带）
    ctypes.WinDLL("msftedit.dll")
    RICHEDIT_CLASS = "RichEdit50W"
except OSError:  # pragma: no cover - 极老的 Windows
    ctypes.WinDLL("riched20.dll")
    RICHEDIT_CLASS = "RichEdit20W"

HWND = wintypes.HWND
UINT = wintypes.UINT
WPARAM = wintypes.WPARAM
LPARAM = wintypes.LPARAM
DWORD = wintypes.DWORD
LONG = wintypes.LONG
HINSTANCE = wintypes.HINSTANCE
HMENU = wintypes.HMENU
LPVOID = wintypes.LPVOID
COLORREF = DWORD

WS_CHILD = 0x40000000
WS_VISIBLE = 0x10000000
WS_VSCROLL = 0x00200000
WS_TABSTOP = 0x00010000
ES_MULTILINE = 0x0004
ES_AUTOVSCROLL = 0x0040
ES_AUTOHSCROLL = 0x0080
ES_NOHIDESEL = 0x0100
ES_WANTRETURN = 0x1000

WM_USER = 0x0400
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_CHAR = 0x0102
WM_SETFOCUS = 0x0007
WM_KILLFOCUS = 0x0008
WM_PAINT = 0x000F
WM_CONTEXTMENU = 0x007B
WM_LBUTTONDOWN = 0x0201
WM_MOUSEWHEEL = 0x020A
WM_SETCURSOR = 0x0020
WM_SETTEXT = 0x000C
WM_GETTEXT = 0x000D
WM_GETTEXTLENGTH = 0x000E
WM_CUT = 0x0300
WM_COPY = 0x0301
WM_PASTE = 0x0302

EM_SETSEL = 0x00B1
EM_GETSEL = 0x00B0
EM_CANUNDO = 0x00C6
EM_CANREDO = 0x0455
EM_SETRECT = 0x00B3
EM_LINESCROLL = 0x00B6
EM_SCROLLCARET = 0x00B7
EM_GETMODIFY = 0x00B8
EM_SETMODIFY = 0x00B9
EM_SETREADONLY = WM_USER + 31
EM_GETLINECOUNT = 0x00BA
EM_REPLACESEL = 0x00C2
EM_REDO = 0x0454
EM_UNDO = 0x00C7
EM_EMPTYUNDOBUFFER = 0x00CD
EM_GETFIRSTVISIBLELINE = 0x00CE
EM_SETMARGINS = 0x00D3
EM_SETCHARFORMAT = 0x0444
EM_SETTARGETDEVICE = 0x0448
EM_SETEDITSTYLE = WM_USER + 195
EM_SETBKGNDCOLOR = WM_USER + 67

SES_USECTF = 0x00010000

SCF_DEFAULT = 0x0000
SCF_ALL = 0x0004
CFM_BOLD = 0x00000001
CFM_COLOR = 0x40000000
CFM_FACE = 0x20000000
CFM_SIZE = 0x80000000
CFE_BOLD = 0x00000001

EC_LEFTMARGIN = 0x0001
EC_RIGHTMARGIN = 0x0002

GWLP_WNDPROC = -4
VK_SHIFT = 0x10
VK_CONTROL = 0x11
VK_MENU = 0x12
VK_TAB = 0x09
VK_RETURN = 0x0D
VK_ESCAPE = 0x1B
VK_F5 = 0x74

SB_VERT = 1
SIF_ALL = 0x0017
GW_OWNER = 4

CachedWndProc = ctypes.WINFUNCTYPE(
    ctypes.c_ssize_t, HWND, UINT, WPARAM, LPARAM
)

CreateWindowExW = user32.CreateWindowExW
CreateWindowExW.restype = HWND
CreateWindowExW.argtypes = [
    DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR, DWORD,
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    HWND, HMENU, HINSTANCE, LPVOID,
]

SendMessageW = user32.SendMessageW
SendMessageW.restype = ctypes.c_ssize_t
SendMessageW.argtypes = [HWND, UINT, WPARAM, ctypes.c_void_p]

# 同一个 SendMessageW，但最后一个参数是字符串指针（EM_REPLACESEL / WM_SETTEXT）。
SendMessageTextW = ctypes.WINFUNCTYPE(
    ctypes.c_ssize_t, HWND, UINT, WPARAM, wintypes.LPCWSTR
)(("SendMessageW", user32))

SetWindowTextW = user32.SetWindowTextW
SetWindowTextW.argtypes = [HWND, wintypes.LPCWSTR]
SetWindowTextW.restype = wintypes.BOOL

CallWindowProcW = user32.CallWindowProcW
CallWindowProcW.restype = ctypes.c_ssize_t
CallWindowProcW.argtypes = [ctypes.c_void_p, HWND, UINT, WPARAM, LPARAM]

SetWindowLongPtrW = user32.SetWindowLongPtrW
SetWindowLongPtrW.restype = ctypes.c_void_p
SetWindowLongPtrW.argtypes = [HWND, ctypes.c_int, ctypes.c_void_p]

GetWindowLongPtrW = user32.GetWindowLongPtrW
GetWindowLongPtrW.restype = ctypes.c_void_p
GetWindowLongPtrW.argtypes = [HWND, ctypes.c_int]

GetModuleHandleW = ctypes.windll.kernel32.GetModuleHandleW
GetModuleHandleW.restype = wintypes.HMODULE
GetModuleHandleW.argtypes = [wintypes.LPCWSTR]

MoveWindow = user32.MoveWindow
MoveWindow.argtypes = [HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.BOOL]

# Tk 会在映射控件时把自己的 Frame 窗口提到最前，把嵌入的原生控件盖住
# （表现是正文空白、点不动）。所以每次布局后都要把控件重新提到 Z 序顶部。
SetWindowPos = user32.SetWindowPos
SetWindowPos.restype = wintypes.BOOL
SetWindowPos.argtypes = [HWND, HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, UINT]

GetWindow = user32.GetWindow
GetWindow.restype = HWND
GetWindow.argtypes = [HWND, UINT]

IsWindowVisible = user32.IsWindowVisible
IsWindowVisible.restype = wintypes.BOOL
IsWindowVisible.argtypes = [HWND]

IsIconic = user32.IsIconic
IsIconic.restype = wintypes.BOOL
IsIconic.argtypes = [HWND]

IsWindow = user32.IsWindow
IsWindow.restype = wintypes.BOOL
IsWindow.argtypes = [HWND]

WM_SHOWWINDOW = 0x0018

EnableWindow = user32.EnableWindow
EnableWindow.restype = wintypes.BOOL
EnableWindow.argtypes = [HWND, wintypes.BOOL]

ShowWindow = user32.ShowWindow
ShowWindow.restype = wintypes.BOOL
ShowWindow.argtypes = [HWND, ctypes.c_int]
ShowWindowAsync = user32.ShowWindowAsync
ShowWindowAsync.restype = wintypes.BOOL
ShowWindowAsync.argtypes = [HWND, ctypes.c_int]
SW_HIDE = 0
SW_SHOW = 5

HWND_TOP = 0
GW_HWNDPREV = 3
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010

SetFocus = user32.SetFocus
SetFocus.argtypes = [HWND]
SetFocus.restype = HWND

GetFocus = user32.GetFocus
GetFocus.restype = HWND

GetCursorPos = user32.GetCursorPos
GetCursorPos.argtypes = [ctypes.c_void_p]
GetCursorPos.restype = wintypes.BOOL

# 正文是原生 RichEdit，光标由它自己的窗口过程负责。挂在 Tk 的窗口层级下时，
# 默认过程对 WM_SETCURSOR 返回箭头而不是 I 形光标（纯 Win32 宿主里正常），
# 所以这里自己接管：客户区一律给 I 形，其它命中区域（滚动条等）交回默认。
SetCursor = user32.SetCursor
SetCursor.argtypes = [wintypes.HANDLE]
SetCursor.restype = wintypes.HANDLE

GetCursor = user32.GetCursor
GetCursor.argtypes = []
GetCursor.restype = wintypes.HANDLE

LoadCursorW = user32.LoadCursorW
LoadCursorW.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
LoadCursorW.restype = wintypes.HANDLE

IDC_IBEAM = 32513
HTCLIENT = 1
_IBEAM_CURSOR = LoadCursorW(None, ctypes.c_void_p(IDC_IBEAM))

GetKeyState = user32.GetKeyState
GetKeyState.argtypes = [ctypes.c_int]
GetKeyState.restype = ctypes.c_short

ShowScrollBar = user32.ShowScrollBar
ShowScrollBar.argtypes = [HWND, ctypes.c_int, wintypes.BOOL]

InvalidateRect = user32.InvalidateRect
InvalidateRect.argtypes = [HWND, ctypes.c_void_p, wintypes.BOOL]

GetClientRect = user32.GetClientRect
GetClientRect.argtypes = [HWND, ctypes.c_void_p]

GetDC = user32.GetDC
GetDC.restype = wintypes.HDC
GetDC.argtypes = [HWND]
ReleaseDC = user32.ReleaseDC
ReleaseDC.argtypes = [HWND, wintypes.HDC]

SelectObject = gdi32.SelectObject
SelectObject.restype = wintypes.HGDIOBJ
SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]

SetBkMode = gdi32.SetBkMode
SetBkMode.argtypes = [wintypes.HDC, ctypes.c_int]
SetBkMode.restype = ctypes.c_int

SetTextColor = gdi32.SetTextColor
SetTextColor.argtypes = [wintypes.HDC, COLORREF]
SetTextColor.restype = COLORREF

CreateFontW = gdi32.CreateFontW
CreateFontW.restype = wintypes.HFONT
CreateFontW.argtypes = [
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    ctypes.c_int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD,
    DWORD, wintypes.LPCWSTR,
]

DeleteObject = gdi32.DeleteObject
DeleteObject.argtypes = [wintypes.HGDIOBJ]
DeleteObject.restype = wintypes.BOOL

GetTextExtentPoint32W = gdi32.GetTextExtentPoint32W
GetTextExtentPoint32W.argtypes = [
    wintypes.HDC, wintypes.LPCWSTR, ctypes.c_int, ctypes.c_void_p,
]
GetTextExtentPoint32W.restype = wintypes.BOOL

TextOutW = gdi32.TextOutW
TextOutW.argtypes = [
    wintypes.HDC, ctypes.c_int, ctypes.c_int,
    wintypes.LPCWSTR, ctypes.c_int,
]
TextOutW.restype = wintypes.BOOL

GetScrollInfo = user32.GetScrollInfo
GetScrollInfo.argtypes = [HWND, ctypes.c_int, ctypes.c_void_p]

OpenClipboard = user32.OpenClipboard
OpenClipboard.argtypes = [HWND]
CloseClipboard = user32.CloseClipboard
GetClipboardData = user32.GetClipboardData
GetClipboardData.restype = wintypes.HANDLE
GetClipboardData.argtypes = [UINT]

IsClipboardFormatAvailable = user32.IsClipboardFormatAvailable
IsClipboardFormatAvailable.argtypes = [UINT]
IsClipboardFormatAvailable.restype = wintypes.BOOL

kernel32 = ctypes.windll.kernel32
GlobalLock = kernel32.GlobalLock
GlobalLock.restype = LPVOID
GlobalLock.argtypes = [wintypes.HGLOBAL]
GlobalUnlock = kernel32.GlobalUnlock
GlobalUnlock.argtypes = [wintypes.HGLOBAL]

CF_UNICODETEXT = 13


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", LONG),
        ("top", LONG),
        ("right", LONG),
        ("bottom", LONG),
    ]


class POINT(ctypes.Structure):
    _fields_ = [("x", LONG), ("y", LONG)]


# 单行输入框只有 18~24px 高时，Tk 在鼠标移动后会把光标改回箭头（原生控件自己
# 设的 I 形光标随后被覆盖）。这里在轮询里兜底：指针停在客户区内就重新设 I 形。
WindowFromPoint = user32.WindowFromPoint
WindowFromPoint.argtypes = [POINT]
WindowFromPoint.restype = HWND

ClientToScreen = user32.ClientToScreen
ClientToScreen.argtypes = [HWND, ctypes.c_void_p]
ClientToScreen.restype = wintypes.BOOL

# 窗口从后台/最小化恢复时，Tk 的根窗口只收到 WM_PAINT，不擦背景
# （见 .perf_msgs.py 记录：恢复那一刻没有 WM_ERASEBKGND）。没有被任何窗口
# 画过的区域由 DWM 按「无内容」合成成纯黑，用户看到的就是整窗闪黑再重画。
# 所以恢复时要抢在 Tk 绘制之前，自己用主题底色把客户区刷一遍。
FillRect = user32.FillRect
FillRect.argtypes = [wintypes.HDC, ctypes.c_void_p, wintypes.HBRUSH]
FillRect.restype = ctypes.c_int

CreateSolidBrush = gdi32.CreateSolidBrush
CreateSolidBrush.restype = wintypes.HBRUSH
CreateSolidBrush.argtypes = [COLORREF]

WM_WINDOWPOSCHANGED = 0x0047


class SCROLLINFO(ctypes.Structure):
    _fields_ = [
        ("cbSize", UINT),
        ("fMask", UINT),
        ("nMin", ctypes.c_int),
        ("nMax", ctypes.c_int),
        ("nPage", UINT),
        ("nPos", ctypes.c_int),
        ("nTrackPos", ctypes.c_int),
    ]


class CHARFORMATW(ctypes.Structure):
    _fields_ = [
        ("cbSize", UINT),
        ("dwMask", DWORD),
        ("dwEffects", DWORD),
        ("yHeight", LONG),
        ("yOffset", LONG),
        ("crTextColor", COLORREF),
        ("bCharSet", wintypes.BYTE),
        ("bPitchAndFamily", wintypes.BYTE),
        ("szFaceName", ctypes.c_wchar * 32),
    ]


def _colorref(hex_color: str) -> int:
    value = hex_color.lstrip("#")
    r, g, b = int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)
    return r | (g << 8) | (b << 16)


class _RepaintGuard:
    """窗口从后台/最小化恢复时，防止正文区先黑一下再重画。

    实测链路（.perf_msgs.py / .check_state.py）：
    - Tk 的根窗口恢复时只收到 WM_PAINT，没有 WM_ERASEBKGND，那块客户区
      在 DWM 眼里「没画过」，合成结果就是纯黑；
    - 与此同时，系统隐式隐藏的原生 RichEdit 子窗口（editor / title_entry /
      tags_entry）在恢复后仍保持 IsWindowVisible=0，要等 Tk 派发 <Map> 才
      慢慢回来，实测 65~100ms。
    两者叠加就是用户看到的「整块正文黑掉，然后重新加载」。

    这里子类化根窗口过程，在恢复的第一时间（IsIconic 由真转假）同时做两件
    事：用主题底色把客户区刷一遍，并立刻把登记过的原生子窗口 ShowWindow
    出来——都发生在 Tk 还没开始重绘之前，把空档期压到看不出来。

    WndProc 里**绝不能调用任何 Tk/Tcl 接口**，否则会触发 GIL 致命崩溃。
    只用 user32/gdi32。
    """

    _ARM_SECONDS = 1.20

    def __init__(self, hwnd: int, color_hex: str) -> None:
        self._hwnd = hwnd
        self._brush = CreateSolidBrush(_colorref(color_hex))
        self._old_proc: int | None = None
        self._was_iconic = bool(IsIconic(hwnd))
        self._armed_until = 0.0
        self._natives: list[int] = []
        self._canvases: dict[int, _CanvasRepaint] = {}
        self._proc = CachedWndProc(self._wndproc)
        old = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, ctypes.cast(self._proc, ctypes.c_void_p))
        if old:
            self._old_proc = old

    # -- 子窗口登记（Tk 侧调用，不在 WndProc 里） -------------------------
    def attach_child(self, child_hwnd: int) -> None:
        """给真正的客户区画布（TkChild）也挂一层补绘。

        根窗口的客户区被 TkChild 完全覆盖，在根窗口上 FillRect 是白做，
        恢复时露黑的那块就是 TkChild 的客户区。
        """
        if not child_hwnd or child_hwnd in self._canvases:
            return
        self._canvases[child_hwnd] = _CanvasRepaint(child_hwnd, self._brush_ref())

    def _brush_ref(self):
        return self._brush

    def register(self, native_hwnd: int) -> None:
        if native_hwnd and native_hwnd not in self._natives:
            self._natives.append(native_hwnd)

    def unregister(self, native_hwnd: int) -> None:
        try:
            self._natives.remove(native_hwnd)
        except ValueError:
            pass

    # -- 窗口过程 ---------------------------------------------------------
    def _wndproc(self, hwnd, msg, wparam, lparam):
        if self._brush and msg in (WM_PAINT, WM_WINDOWPOSCHANGED, WM_SHOWWINDOW):
            now = time.monotonic()
            iconic = bool(IsIconic(hwnd))
            if self._was_iconic and not iconic:
                self._armed_until = now + self._ARM_SECONDS
                self._arm_all()
                self._restore_natives()
                self._paint_now(hwnd)
            elif now < self._armed_until and not iconic:
                self._arm_all()
                self._restore_natives()
                self._paint_now(hwnd)
            self._was_iconic = iconic
        return CallWindowProcW(self._old_proc, hwnd, msg, wparam, lparam)

    def _arm_all(self) -> None:
        """恢复瞬间：让每个画布层的下一次 WM_PAINT 先补底色。"""
        for canvas in list(self._canvases.values()):
            canvas.arm()

    def should_fill(self) -> bool:
        """当前是否处于「刚从后台恢复」的补绘窗口内。"""
        return self._brush is not None and time.monotonic() < self._armed_until

    def fill_native(self, hwnd) -> None:
        """给已登记的原生控件铺一层底色（WndProc 内调用，只能碰 gdi32）。"""
        self._paint_now(hwnd)

    def _restore_natives(self) -> None:
        """把系统隐式隐藏的原生子窗口立刻显示出来，并让它们重画。

        恢复过程中系统会推迟子窗口的 WS_VISIBLE 生效，同步 ShowWindow 实测
        要 65~100ms 才看到 IsWindowVisible 变 1。ShowWindowAsync 把请求直接
        排进目标线程的队列，不等结果，实测更快，所以优先用它。
        """
        for hwnd in list(self._natives):
            try:
                if not IsWindow(hwnd):
                    continue
                if not IsWindowVisible(hwnd):
                    if not ShowWindowAsync(hwnd, SW_SHOW):
                        ShowWindow(hwnd, SW_SHOW)
                # 不等它自己 WM_PAINT，立刻铺一层底色：从 POSCHANGED 到第一
                # 个 WM_PAINT 之间的空档正是用户看到的那块黑。
                self._paint_now(hwnd)
                InvalidateRect(hwnd, None, False)
            except Exception:
                continue

    def _paint_now(self, hwnd) -> None:
        """用底色直接填客户区，不产生新消息，也不碰 Tk。"""
        brush = self._brush
        if not brush:
            return
        hdc = GetDC(hwnd)
        if not hdc:
            return
        try:
            rect = RECT()
            if GetClientRect(hwnd, ctypes.byref(rect)):
                FillRect(hdc, ctypes.byref(rect), brush)
        finally:
            ReleaseDC(hwnd, hdc)

    def dispose(self) -> None:
        for canvas in list(self._canvases.values()):
            canvas.dispose()
        self._canvases.clear()
        if self._old_proc:
            SetWindowLongPtrW(self._hwnd, GWLP_WNDPROC, ctypes.c_void_p(self._old_proc))
            self._old_proc = None
        self._natives.clear()
        if self._brush:
            DeleteObject(self._brush)
            self._brush = None


class _CanvasRepaint:
    """给 TkChild（真正的客户区画布）在恢复瞬间补一层底色。

    恢复时 TkChild 收到 WM_PAINT 却没有 WM_ERASEBKGND，露出的那块区域在
    DWM 眼里从未被绘制，合成成纯黑。这里在 WM_PAINT 交回 Tk 之前先 FillRect：
    Tk 随后会把真正的内容覆盖上去，补的底色只在空档期可见。
    """

    def __init__(self, hwnd: int, brush) -> None:
        self._hwnd = hwnd
        self._brush = brush
        self._old_proc: int | None = None
        self._until = 0.0
        self._fills = 0
        self._proc = CachedWndProc(self._wndproc)
        old = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, ctypes.cast(self._proc, ctypes.c_void_p))
        if old:
            self._old_proc = old

    def arm(self, seconds: float = 1.2) -> None:
        self._until = time.monotonic() + seconds

    def _wndproc(self, hwnd, msg, wparam, lparam):
        if msg == WM_PAINT and self._brush and time.monotonic() < self._until:
            self._fills += 1
            self._fill(hwnd)
        return CallWindowProcW(self._old_proc, hwnd, msg, wparam, lparam)

    def _fill(self, hwnd) -> None:
        hdc = GetDC(hwnd)
        if not hdc:
            return
        try:
            rect = RECT()
            if GetClientRect(hwnd, ctypes.byref(rect)):
                FillRect(hdc, ctypes.byref(rect), self._brush)
        finally:
            ReleaseDC(hwnd, hdc)

    def dispose(self) -> None:
        if self._old_proc:
            SetWindowLongPtrW(self._hwnd, GWLP_WNDPROC, ctypes.c_void_p(self._old_proc))
            self._old_proc = None


def install_repaint_guard(widget, color_hex: str) -> _RepaintGuard | None:
    """给 Tk 主窗口装上恢复时的补绘保护，失败时静默返回 None。

    要挂两个窗口：根窗口（TkTopLevel，最小化/恢复的状态位在它身上）和它
    里面的 TkChild（widget.winfo_id()，真正的客户区画布）。根窗口那一层的
    FillRect 会被 TkChild 整片盖住，只挂根窗口等于什么都没做。
    """
    try:
        root = user32.GetAncestor(widget.winfo_id(), 2)  # GA_ROOT
        child = widget.winfo_id()
        guard = _RepaintGuard(root, color_hex)
        if child and child != root:
            guard.attach_child(child)
        return guard
    except Exception:
        LOG.exception("安装重绘保护失败")
        return None


class RichEdit(tk.Frame):
    """把原生 RichEdit 嵌进 Tk，并模拟常用的 Text / Entry 接口。"""

    def __init__(
        self,
        master,
        *,
        text: str = "",
        font_family: str = "Microsoft YaHei UI",
        font_size: int = 12,
        bold: bool = False,
        fg: str = "#3B3323",
        bg: str = "#FFFDF2",
        placeholder: str = "",
        placeholder_color: str = "#C9BC8C",
        multiline: bool = True,
        height: int = 0,
        inset: tuple[int, int, int, int] = (0, 0, 0, 0),
        on_change: Callable[[], None] | None = None,
        on_enter: Callable[[], None] | None = None,
        on_tab: Callable[[], None] | None = None,
        on_escape: Callable[[], None] | None = None,
        on_context: Callable[[int, int], None] | None = None,
        on_shortcut: Callable[[str], None] | None = None,
        on_click: Callable[[], None] | None = None,
    ) -> None:
        super().__init__(master, bd=0, highlightthickness=0, bg=bg)
        if height:
            self.configure(height=height)
            self.grid_propagate(False)

        self._multiline = multiline
        self._fg = fg
        self._bg = bg
        self._font_family = font_family
        self._font_size = font_size
        self._bold = bold
        self._placeholder = placeholder
        self._placeholder_color = placeholder_color
        self._inset = inset
        self._on_change = on_change
        self._on_enter = on_enter
        self._on_tab = on_tab
        self._on_escape = on_escape
        self._on_context = on_context
        self._on_shortcut = on_shortcut
        self._on_click = on_click
        self._yscrollcommand = None
        self._last_text = ""
        self._last_scroll = None
        self._pending_action: str | None = None
        self._pending_text = ""
        self._pending_context: tuple[int, int] | None = None
        self._swallow_char = False
        self._input_blocked = False
        self._after_id = None
        self._cursor_after_id = None
        self._font_handle = None
        self._alive = True
        self._in_poll = False

        # 把原生控件挂到本控件自己的 Frame 窗口下，这样 Tk 的 map/unmap
        # （例如切到预览、隐藏编辑器）会自动带上原生控件。挂在父容器下的话，
        # 控件是 Frame 的兄弟窗口，Frame 被隐藏后它还会留在屏幕上盖住预览。
        parent = HWND(self.winfo_id())
        style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_NOHIDESEL
        if multiline:
            style |= (
                WS_VSCROLL
                | ES_MULTILINE
                | ES_AUTOVSCROLL
                | ES_WANTRETURN
            )
        else:
            style |= ES_AUTOHSCROLL

        self._hwnd = CreateWindowExW(
            0,
            RICHEDIT_CLASS,
            "",
            style,
            0,
            0,
            max(10, self.winfo_width()),
            max(10, self.winfo_height()),
            parent,
            None,
            GetModuleHandleW(None),
            None,
        )
        if not self._hwnd:
            raise OSError("无法创建 RichEdit 控件")

        # TSF：RichEdit 4.1 默认已接入；这个标志在支持的版本上进一步显式开启。
        try:
            SendMessageW(self._hwnd, EM_SETEDITSTYLE, SES_USECTF, SES_USECTF)
        except Exception:
            pass

        SendMessageW(self._hwnd, EM_SETBKGNDCOLOR, 0, _colorref(bg))
        SendMessageW(
            self._hwnd,
            EM_SETMARGINS,
            EC_LEFTMARGIN | EC_RIGHTMARGIN,
            0,
        )
        if multiline:
            # 让 RichEdit 按窗口宽度自动换行
            SendMessageW(self._hwnd, EM_SETTARGETDEVICE, 0, 0)
            ShowScrollBar(self._hwnd, SB_VERT, False)

        self._create_font_handle()
        self._apply_format()
        self.set_text(text)
        self._hidden = False
        self._last_geometry = None

        self._wndproc_ref = CachedWndProc(self._wndproc)
        self._old_proc = SetWindowLongPtrW(
            self._hwnd,
            GWLP_WNDPROC,
            ctypes.cast(self._wndproc_ref, ctypes.c_void_p),
        )

        self.bind("<Configure>", self._on_configure, add="+")
        self.bind("<Destroy>", self._on_destroy, add="+")
        self.bind("<Map>", self._on_map, add="+")
        # 主窗口恢复时要把原生子窗口一并拉起来，所以登记到根窗口的守卫里。
        self._repaint_guard = None
        try:
            guard = getattr(self.winfo_toplevel(), "_repaint_guard", None)
            if guard is not None:
                guard.register(self._hwnd)
                self._repaint_guard = guard
        except Exception:
            LOG.exception("登记原生控件失败")
        self.after(30, self._on_configure)
        self._after_id = self.after(80, self._poll)
        self._cursor_after_id = self.after(150, self._cursor_tick)

    # ------------------------------------------------------------------
    # 原生消息
    # ------------------------------------------------------------------
    def _wndproc(self, hwnd, msg, wparam, lparam):
        try:
            if msg == WM_PAINT:
                # 刚从后台恢复时，这块客户区在 DWM 眼里「没画过」，
                # 在 RichEdit 真正绘制之前先铺一层自身底色，避免露出纯黑。
                guard = getattr(self, "_repaint_guard", None)
                if guard is not None and guard.should_fill():
                    guard.fill_native(hwnd)
            elif msg == WM_KEYDOWN:
                self._swallow_char = False
                if self._handle_keydown(hwnd, wparam):
                    return 0
            elif msg == WM_CHAR:
                # 被 Tk 侧接管的 Tab / 回车，RichEdit 仍会收到对应的 WM_CHAR，
                # 这里把它吞掉，否则会额外插入一个 \t 或 \r。
                if self._swallow_char:
                    self._swallow_char = False
                    return 0
            elif msg == WM_LBUTTONDOWN:
                # 原生子窗口不参与 Tk 的事件冒泡，点正文时主窗口收不到点击；
                # 这里记一笔，交给 _poll 通知 Tk（例如收起「⋯」菜单）。
                self._pending_action = "click"
            elif msg == WM_CONTEXTMENU:
                x = ctypes.c_short(lparam & 0xFFFF).value
                y = ctypes.c_short((lparam >> 16) & 0xFFFF).value
                if x == -1 and y == -1:
                    point = POINT()
                    user32.GetCursorPos(ctypes.byref(point))
                    x, y = point.x, point.y
                self._pending_context = (x, y)
                return 0
            elif msg == WM_SETCURSOR:
                # Tk 宿主下 RichEdit 的默认过程不会给 I 形光标，这里自己设。
                if (lparam & 0xFFFF) == HTCLIENT:
                    SetCursor(_IBEAM_CURSOR)
                    return 1
            elif msg == WM_PAINT:
                result = CallWindowProcW(
                    self._old_proc, hwnd, msg, wparam, lparam
                )
                self._paint_placeholder()
                return result
            elif msg in (WM_SETFOCUS, WM_KILLFOCUS):
                result = CallWindowProcW(
                    self._old_proc, hwnd, msg, wparam, lparam
                )
                InvalidateRect(self._hwnd, None, True)
                return result
        except Exception:
            LOG.exception("RichEdit 消息处理失败")
        return CallWindowProcW(self._old_proc, hwnd, msg, wparam, lparam)

    def _handle_keydown(self, hwnd, vk: int) -> bool:
        if self._input_blocked:
            # 面板 / 卡片挡在正文前面时，按键不再落到便签里，只把 Esc 转出去。
            if vk == VK_ESCAPE:
                self._pending_action = "escape"
            return True

        ctrl = bool(GetKeyState(VK_CONTROL) & 0x8000)
        shift = bool(GetKeyState(VK_SHIFT) & 0x8000)
        alt = bool(GetKeyState(VK_MENU) & 0x8000)

        if vk == VK_TAB and not ctrl and not alt and not shift:
            self._swallow_char = True
            if self._multiline:
                self._pending_text += "    "
            else:
                self._pending_action = "tab"
            return True

        if vk == VK_RETURN and not self._multiline and not ctrl and not alt:
            self._swallow_char = True
            self._pending_action = "enter"
            return True

        if vk == VK_ESCAPE:
            self._pending_action = "escape"
            return True

        if vk == VK_F5 and not ctrl and not alt:
            self._pending_action = "backup"
            return True

        if ctrl and not alt:
            mapping = {
                ord("N"): "new",
                ord("S"): "save",
                ord("F"): "find",
                ord("D"): "delete",
                ord("R"): "refresh",
                ord("E"): "preview",
                ord("L"): "lock",
                ord("V"): "paste",
                ord("1"): "mode0",
                ord("2"): "mode1",
                0xBC: "settings",  # Ctrl+,
            }
            action = mapping.get(vk)
            if action:
                self._pending_action = action
                return True
        return False

    # ------------------------------------------------------------------
    # 轮询：比在 WndProc 里直接调 Tk 安全
    # ------------------------------------------------------------------
    def _poll(self) -> None:
        if not self._alive:
            return
        self._in_poll = True
        try:
            self._ensure_on_top()

            if self._pending_action:
                action = self._pending_action
                self._pending_action = None
                self._dispatch(action)

            if self._pending_text:
                text = self._pending_text
                self._pending_text = ""
                self.insert("insert", text)

            if self._pending_context is not None:
                x, y = self._pending_context
                self._pending_context = None
                if self._on_context is not None:
                    self._on_context(x, y)

            if self._on_change is not None and SendMessageW(
                self._hwnd, EM_GETMODIFY, 0, 0
            ):
                current = self.get_text()
                if current != self._last_text:
                    self._last_text = current
                    self._on_change()

            self._sync_scrollbar()
        except Exception:
            LOG.exception("RichEdit 轮询失败")
        finally:
            self._in_poll = False
        if self._alive:
            self._after_id = self.after(80, self._poll)

    def _dispatch(self, action: str) -> None:
        if action == "click":
            if self._on_click is not None:
                self._on_click()
            return
        if action == "enter":
            callback = self._on_enter
        elif action == "tab":
            callback = self._on_tab
        elif action == "escape":
            callback = self._on_escape
        elif action == "paste":
            self.paste()
            return
        else:
            callback = None
            if self._on_shortcut is not None:
                self._on_shortcut(action)
                return
        if callback is not None:
            callback()

    # ------------------------------------------------------------------
    # 外观
    # ------------------------------------------------------------------
    def _create_font_handle(self) -> None:
        try:
            scaling = float(self.winfo_toplevel().tk.call("tk", "scaling"))
        except Exception:
            scaling = 1.333
        pixel = max(8, round(self._font_size * scaling))
        self._font_handle = gdi32.CreateFontW(
            -pixel,
            0,
            0,
            0,
            700 if self._bold else 400,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            self._font_family,
        )

    def _apply_format(self) -> None:
        cf = CHARFORMATW()
        cf.cbSize = ctypes.sizeof(CHARFORMATW)
        cf.dwMask = CFM_FACE | CFM_SIZE | CFM_COLOR | CFM_BOLD
        cf.dwEffects = CFE_BOLD if self._bold else 0
        cf.yHeight = self._font_size * 20
        cf.crTextColor = _colorref(self._fg)
        cf.szFaceName = self._font_family
        ptr = ctypes.cast(ctypes.byref(cf), ctypes.c_void_p)
        SendMessageW(self._hwnd, EM_SETCHARFORMAT, SCF_DEFAULT, ptr)
        SendMessageW(self._hwnd, EM_SETCHARFORMAT, SCF_ALL, ptr)

    def _paint_placeholder(self) -> None:
        if not self._placeholder or not self._hwnd:
            return
        if SendMessageW(self._hwnd, WM_GETTEXTLENGTH, 0, 0):
            return
        hdc = GetDC(self._hwnd)
        if not hdc:
            return
        try:
            rect = RECT()
            GetClientRect(self._hwnd, ctypes.byref(rect))
            old_font = None
            if self._font_handle:
                old_font = gdi32.SelectObject(hdc, self._font_handle)
            gdi32.SetBkMode(hdc, 1)  # TRANSPARENT
            gdi32.SetTextColor(hdc, _colorref(self._placeholder_color))

            size = wintypes.SIZE()
            gdi32.GetTextExtentPoint32W(
                hdc,
                self._placeholder,
                len(self._placeholder),
                ctypes.byref(size),
            )
            y = max(0, (rect.bottom - rect.top - size.cy) // 2)
            gdi32.TextOutW(
                hdc,
                0,
                y,
                self._placeholder,
                len(self._placeholder),
            )
            if old_font:
                gdi32.SelectObject(hdc, old_font)
        finally:
            ReleaseDC(self._hwnd, hdc)

    def _on_map(self, _event=None) -> None:
        """父窗口重新可见（从最小化恢复、切换虚拟桌面）时立刻把原生控件显出来。

        RichEdit 是独立的 HWND：窗口最小化时系统会把它隐藏，恢复时要等它
        自己重新 Map 再重绘，实测有 3 帧左右（约 150ms）的窗口期。这段时间
        父窗口已经画好，而正文区域里什么都没画，露出的就是黑底——这就是
        「从后台切回来整个内容变黑再重新加载」。
        主动 ShowWindow + InvalidateRect 可以把这个空档压到 1 帧以内。
        """
        if not self._alive or not self._hwnd or self._hidden:
            return
        try:
            ShowWindow(self._hwnd, SW_SHOW)
            InvalidateRect(self._hwnd, None, False)
            self._on_configure()
            self._raise_to_top()
        except Exception:
            LOG.exception("恢复原生控件失败")

    def _on_configure(self, _event=None) -> None:
        if not self._alive or not self._hwnd:
            return
        width = max(10, self.winfo_width())
        height = max(10, self.winfo_height())
        left, top, right, bottom = self._inset
        geometry = (left, top, max(4, width - left - right), max(4, height - top - bottom))
        # 尺寸没变就不要动原生窗口。窗口从后台恢复时 Tk 会连发好几次
        # <Configure>，每次都 SetWindowPos 会让 RichEdit 反复 WM_SIZE 重排，
        # 重排期间客户区是未绘制状态，视觉上就是正文整块黑一帧。
        if geometry == self._last_geometry:
            return
        self._last_geometry = geometry
        # 只改位置和尺寸，不要碰 z 序。
        SetWindowPos(
            self._hwnd,
            HWND_TOP,
            geometry[0],
            geometry[1],
            geometry[2],
            geometry[3],
            SWP_NOACTIVATE | SWP_NOZORDER,
        )

    def _raise_to_top(self) -> None:
        if not self._hwnd or self._hidden:
            return
        # 只在确实被别的同级窗口盖住时才动 z 序。无条件 HWND_TOP 会让控件在
        # 每次 <Map>/焦点变化时重新参与合成，从后台切回窗口能看到正文先黑一帧。
        prev = GetWindow(self._hwnd, GW_HWNDPREV)
        if not (prev and IsWindowVisible(prev)):
            return
        SetWindowPos(
            self._hwnd,
            HWND_TOP,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        )

    def _keep_cursor(self) -> bool:
        """指针停在客户区内时保住 I 形光标，返回指针是否在控件内。

        RichEdit 自己在 WM_SETCURSOR 里设的 I 形光标，在单行小尺寸控件上会被
        Tk 随后的光标更新覆盖成箭头（正文高度够大时不受影响）。这里补设回去。
        """
        if not self._hwnd or not IsWindowVisible(self._hwnd):
            return False
        point = POINT()
        if not GetCursorPos(ctypes.byref(point)):
            return False
        if WindowFromPoint(point) != self._hwnd:
            return False
        rect = RECT()
        if not GetClientRect(self._hwnd, ctypes.byref(rect)):
            return False
        origin = POINT(0, 0)
        if not ClientToScreen(self._hwnd, ctypes.byref(origin)):
            return False
        local_x = point.x - origin.x
        local_y = point.y - origin.y
        if not (rect.left <= local_x < rect.right and rect.top <= local_y < rect.bottom):
            return False
        if user32.GetCursor() != _IBEAM_CURSOR:
            SetCursor(_IBEAM_CURSOR)
        return True

    def _cursor_tick(self) -> None:
        """悬停时高频补光标，指针离开后降频待命。"""
        self._cursor_after_id = None
        if not self._alive:
            return
        try:
            inside = self._keep_cursor()
        except Exception:
            inside = False
        if self._alive:
            self._cursor_after_id = self.after(25 if inside else 150, self._cursor_tick)

    def _ensure_on_top(self) -> None:
        """Tk 的 Frame 窗口随时可能被提到最前，把原生控件盖住。"""
        if not self._hwnd:
            return
        prev = GetWindow(self._hwnd, GW_HWNDPREV)
        if prev and IsWindowVisible(prev):
            self._raise_to_top()

    def _on_destroy(self, _event=None) -> None:
        self._alive = False
        if getattr(self, "_repaint_guard", None) is not None and self._hwnd:
            try:
                self._repaint_guard.unregister(self._hwnd)
            except Exception:
                pass
            self._repaint_guard = None
        if self._after_id is not None:
            try:
                self.after_cancel(self._after_id)
            except Exception:
                pass
            self._after_id = None
        if self._cursor_after_id is not None:
            try:
                self.after_cancel(self._cursor_after_id)
            except Exception:
                pass
            self._cursor_after_id = None
        if self._font_handle:
            try:
                gdi32.DeleteObject(self._font_handle)
            except Exception:
                pass
            self._font_handle = None

    # ------------------------------------------------------------------
    # Text 兼容接口
    # ------------------------------------------------------------------
    def set_text(self, text: str) -> None:
        self._loading_text = True
        try:
            SetWindowTextW(self._hwnd, (text or "").replace("\n", "\r"))
            SendMessageW(self._hwnd, EM_EMPTYUNDOBUFFER, 0, 0)
            SendMessageW(self._hwnd, EM_SETMODIFY, 0, 0)
            self._last_text = self.get_text()
            InvalidateRect(self._hwnd, None, True)
        finally:
            self._loading_text = False

    def get_text(self) -> str:
        length = int(SendMessageW(self._hwnd, WM_GETTEXTLENGTH, 0, 0))
        if length <= 0:
            return ""
        buffer = ctypes.create_unicode_buffer(length * 2 + 8)
        copied = SendMessageTextW(
            self._hwnd,
            WM_GETTEXT,
            len(buffer),
            buffer,
        )
        if copied <= 0:
            return ""
        return buffer.value.replace("\r\n", "\n").replace("\r", "\n")

    def get(self, _start: str = "1.0", _end: str = "end-1c") -> str:
        return self.get_text()

    def insert(self, index: str, text: str) -> None:
        if not text:
            return
        if index == "1.0":
            SendMessageW(self._hwnd, EM_SETSEL, 0, 0)
        elif index == "end":
            SendMessageW(self._hwnd, EM_SETSEL, -1, -1)
        elif index != "insert":
            raise ValueError(f"不支持的插入位置：{index}")
        SendMessageTextW(
            self._hwnd,
            EM_REPLACESEL,
            1,
            text.replace("\n", "\r"),
        )
        InvalidateRect(self._hwnd, None, True)

    def delete(self, _start: str = "1.0", _end: str = "end") -> None:
        self.set_text("")

    def mark_saved(self) -> None:
        self._last_text = self.get_text()
        SendMessageW(self._hwnd, EM_SETMODIFY, 0, 0)

    def edit_modified(self, flag: bool | None = None) -> bool:
        if flag is not None:
            SendMessageW(self._hwnd, EM_SETMODIFY, 1 if flag else 0, 0)
            if not flag:
                self._last_text = self.get_text()
            return bool(flag)
        return bool(SendMessageW(self._hwnd, EM_GETMODIFY, 0, 0))

    def edit_reset(self) -> None:
        SendMessageW(self._hwnd, EM_EMPTYUNDOBUFFER, 0, 0)
        SendMessageW(self._hwnd, EM_SETMODIFY, 0, 0)

    def undo(self) -> None:
        SendMessageW(self._hwnd, EM_UNDO, 0, 0)

    def redo(self) -> None:
        SendMessageW(self._hwnd, EM_REDO, 0, 0)

    def cut(self) -> None:
        SendMessageW(self._hwnd, WM_CUT, 0, 0)

    def copy(self) -> None:
        SendMessageW(self._hwnd, WM_COPY, 0, 0)

    def paste(self) -> None:
        """只粘贴纯文本，避免把 Word / 网页的字体颜色带进 Markdown。"""
        text = ""
        if OpenClipboard(self._hwnd):
            try:
                handle = GetClipboardData(CF_UNICODETEXT)
                if handle:
                    pointer = GlobalLock(handle)
                    if pointer:
                        try:
                            text = ctypes.wstring_at(pointer)
                        finally:
                            GlobalUnlock(handle)
            finally:
                CloseClipboard()
        if text:
            self.insert("insert", text.replace("\r\n", "\n"))

    def select_all(self) -> None:
        SendMessageW(self._hwnd, EM_SETSEL, 0, -1)

    def can_undo(self) -> bool:
        return bool(self._hwnd) and bool(SendMessageW(self._hwnd, EM_CANUNDO, 0, 0))

    def can_redo(self) -> bool:
        return bool(self._hwnd) and bool(SendMessageW(self._hwnd, EM_CANREDO, 0, 0))

    def has_selection(self) -> bool:
        if not self._hwnd:
            return False
        start = ctypes.c_uint32(0)
        end = ctypes.c_uint32(0)
        SendMessageW(
            self._hwnd,
            EM_GETSEL,
            ctypes.addressof(start),
            ctypes.addressof(end),
        )
        return start.value != end.value

    def can_paste(self) -> bool:
        return bool(self._hwnd) and bool(IsClipboardFormatAvailable(CF_UNICODETEXT))

    def clear_selection(self) -> None:
        SendMessageW(self._hwnd, EM_SETSEL, 0, 0)

    def mark_set(self, _index: str, _where: str) -> None:
        self.clear_selection()
        SendMessageW(self._hwnd, EM_SCROLLCARET, 0, 0)

    # ------------------------------------------------------------------
    # 滚动条
    # ------------------------------------------------------------------
    def set_yscrollcommand(self, callback) -> None:
        self._yscrollcommand = callback
        self._sync_scrollbar()

    def yview(self, *args) -> None:
        if not args:
            self._sync_scrollbar()
            return
        if args[0] == "moveto":
            try:
                self.yview_moveto(float(args[1]))
            except (IndexError, ValueError):
                pass
        elif args[0] == "scroll":
            try:
                amount = int(args[1])
            except (IndexError, ValueError):
                return
            unit = args[2] if len(args) > 2 else "units"
            page = 1
            if unit == "pages":
                page = 10
            SendMessageW(
                self._hwnd,
                EM_LINESCROLL,
                0,
                amount * page,
            )
            self._sync_scrollbar()

    def yview_moveto(self, fraction: float) -> None:
        total = int(SendMessageW(self._hwnd, EM_GETLINECOUNT, 0, 0))
        first = int(
            SendMessageW(self._hwnd, EM_GETFIRSTVISIBLELINE, 0, 0)
        )
        target = max(0, int(total * max(0.0, min(1.0, fraction))))
        SendMessageW(self._hwnd, EM_LINESCROLL, 0, target - first)
        self._sync_scrollbar()

    def _sync_scrollbar(self) -> None:
        callback = self._yscrollcommand
        if callback is None or not self._hwnd:
            return
        info = SCROLLINFO()
        info.cbSize = ctypes.sizeof(SCROLLINFO)
        info.fMask = SIF_ALL
        if not GetScrollInfo(self._hwnd, SB_VERT, ctypes.byref(info)):
            return
        page = max(1, int(info.nPage))
        total = max(1, int(info.nMax) + page)
        first = max(0.0, min(1.0, info.nPos / total))
        last = max(first, min(1.0, (info.nPos + page) / total))
        state = (round(first, 4), round(last, 4))
        if state != self._last_scroll:
            self._last_scroll = state
            try:
                callback(first, last)
            except Exception:
                LOG.exception("更新滚动条失败")

    # ------------------------------------------------------------------
    # 焦点
    # ------------------------------------------------------------------
    def focus_set(self) -> None:  # type: ignore[override]
        try:
            self._raise_to_top()
            SetFocus(self._hwnd)
        except Exception:
            pass

    def has_focus(self) -> bool:
        """控件是否持有键盘焦点（用于避免自动保存打断正在进行的输入）。"""
        return bool(self._hwnd) and GetFocus() == self._hwnd

    def set_input_enabled(self, enabled: bool) -> None:
        """面板盖住正文时禁用原生控件，按键就不会落进便签。"""
        if not self._hwnd:
            return
        self._input_blocked = not enabled
        try:
            EnableWindow(self._hwnd, bool(enabled))
        except Exception:
            LOG.exception("切换 RichEdit 可用状态失败")

    def set_visible(self, visible: bool) -> None:
        """面板盖住正文时把原生窗口整个藏起来。

        原生 HWND 的 z 序由 Win32 管理，Tk 的 lift()/lower() 改不动它：
        面板 lift() 到最上层，正文照样画在面板之上，视觉上就是
        「设置/私密库跑到了主页面下方」。只有 ShowWindow 能真正解决。
        """
        if not self._hwnd:
            return
        self._hidden = not visible
        try:
            ShowWindow(self._hwnd, SW_SHOW if visible else SW_HIDE)
        except Exception:
            LOG.exception("切换 RichEdit 可见状态失败")

    def input_enabled(self) -> bool:
        if not self._hwnd:
            return False
        return bool(user32.IsWindowEnabled(self._hwnd))
