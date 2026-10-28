"""Windows 11 原生标题栏配色。

把系统绘制的标题栏 / 边框改成便签纸的颜色，让窗口看起来一体化，
同时保留原生窗口的能力：任务栏、最小化、贴边、缩放、无障碍。
参考 DwmSetWindowAttribute：DWMWA_BORDER_COLOR=34 / CAPTION_COLOR=35 / TEXT_COLOR=36。
"""

from __future__ import annotations

import ctypes
import sys

_BORDER = 34
_CAPTION = 35
_TEXT = 36
_GA_ROOT = 2


def _colorref(value: str) -> int:
    """#RRGGBB -> Windows COLORREF (0x00BBGGRR)。"""
    raw = value.lstrip("#")
    r, g, b = int(raw[0:2], 16), int(raw[2:4], 16), int(raw[4:6], 16)
    return r | (g << 8) | (b << 16)


def _hwnd(widget) -> int:
    handle = ctypes.windll.user32.GetAncestor(widget.winfo_id(), _GA_ROOT)
    return handle or widget.winfo_id()


def apply(widget, caption: str, text: str, border: str) -> bool:
    """给顶层窗口套用配色；非 Windows 或旧系统上静默失败。"""
    if sys.platform != "win32":
        return False
    try:
        hwnd = _hwnd(widget)
        for attribute, color in (
            (_CAPTION, caption),
            (_TEXT, text),
            (_BORDER, border),
        ):
            value = ctypes.c_int(_colorref(color))
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, attribute, ctypes.byref(value), ctypes.sizeof(value)
            )
        return True
    except Exception:  # pragma: no cover - 取决于系统版本
        return False
