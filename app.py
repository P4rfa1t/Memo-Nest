#!/usr/bin/env python3
"""MemoNest —— 便签式 Markdown 备忘录（CustomTkinter 界面 / OneDrive 云备份 / GitHub）。"""

from __future__ import annotations

import logging
import os
import queue
import re
import threading
import tkinter as tk
import webbrowser
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path
from tkinter import filedialog, messagebox

try:
    import customtkinter as ctk
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "缺少 customtkinter。请运行 start.bat（会自动创建虚拟环境并安装依赖），"
        "或执行：.venv\\bin\\python -m pip install -r requirements.txt"
    ) from exc

from core import autostart, backup, hello, onedrive, shortcut, winstyle
from core import config as cfgmod
from core.markdown import MarkdownView
from core.storage import Note, Store, fmt_time
from core.vault import Vault, VaultStore

LOG = logging.getLogger("memonest")


def apply_icon(window) -> None:
    """给任意 Toplevel 套上同一个便签图标。"""
    icon = cfgmod.ICON_PATH
    if not icon.exists():
        return
    try:
        window.iconbitmap(default=str(icon))
    except tk.TclError:  # pragma: no cover - 非 Windows
        pass


def validate_new_password(values: list[str]) -> str | None:
    """主密码长度与二次确认。"""
    if len(values[0] or "") < 6:
        return "主密码至少 6 位"
    if values[0] != values[1]:
        return "两次输入的密码不一致"
    return None


def validate_change_password(values: list[str]) -> str | None:
    """更改主密码：验证当前密码、新密码长度与二次确认。"""
    if not values[0]:
        return "请输入当前主密码"
    if len(values[1] or "") < 6:
        return "新密码至少 6 位"
    if values[1] != values[2]:
        return "两次输入的新密码不一致"
    if values[0] == values[1]:
        return "新密码不能与当前密码相同"
    return None

PALETTE = {
    "bg": "#FFF8D9",
    "panel": "#FFF8D9",
    "card": "#FFFDF2",
    "field": "#FBF1C7",
    "strip": "#F5E7B0",
    "fg": "#3B3323",
    "muted": "#93865B",
    "accent": "#E3B23C",
    "accent_hover": "#D6A22C",
    "link": "#2563EB",
    "border": "#EDE0AC",
    "code_bg": "#F6E9B5",
    "code_fg": "#8A5A00",
    "selection": "#F0DFA0",
}

FONT_FAMILY = "Microsoft YaHei UI"
MONO_FAMILY = "Consolas"

WELCOME = """\
这是一张可以一直贴在桌面上的便签。标题写在上方，正文直接写 Markdown。

## 快速上手

- 顶部下拉框切换便签，按 `+` 新建
- 内容会自动保存，`Ctrl+S` 也可以手动保存
- 点「预览」查看渲染效果，再点一次回到编辑
- 「置顶」让窗口停留最前，像真正的便签一样
- `Ctrl+F` 搜索便签，`Ctrl+D` 删除当前便签

## 支持的 Markdown

| 语法 | 效果 |
| --- | --- |
| `# 标题` | 一到六级标题 |
| `**加粗**` / `*斜体*` | 强调文字 |
| `` `代码` `` | 行内代码 |
| 三个反引号 | 代码块 |
| `- 项目` / `1. 项目` | 列表与任务列表 |
| `> 引用` | 引用块 |
| `[文字](链接)` | 超链接 |

## 云备份

在「设置 → OneDrive」中启用备份，有两种方式：

- 文件夹：把备份包与笔记复制到 OneDrive 同步文件夹，由客户端自动上传
- Microsoft 账号：直接登录账号，把备份上传到云端（无需安装 OneDrive 客户端）

也可以在「设置 → GitHub」中填写仓库与 Token，把笔记推送成仓库里的 Markdown 文件。

## 私密笔记库（可选）

有些便签比较私密？在「设置 → 私密库」创建密码后，把那条便签
「移到私密笔记库」即可。顶栏切到「私密」并解锁后才能查看，
其余便签仍然是普通的 Markdown 明文。

## 小提示

- 删除的便签会移动到 `data/trash/`，随时可以手动找回
- 普通便签文件就是 `data/notes/*.md`，可随时用其他编辑器打开
- 在「设置 → 通用」中可开启开机自启
"""


def setup_logging() -> None:
    cfgmod.ensure_dirs()
    logger = logging.getLogger()
    if logger.handlers:
        return
    logger.setLevel(logging.INFO)
    handler = RotatingFileHandler(
        cfgmod.LOG_PATH, maxBytes=512 * 1024, backupCount=2, encoding="utf-8"
    )
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    logger.addHandler(handler)


class MemoApp(ctk.CTk):
    def __init__(self, cfg: cfgmod.Config | None = None) -> None:
        ctk.set_appearance_mode("light")
        super().__init__(fg_color=PALETTE["bg"])
        cfgmod.ensure_dirs()
        self.cfg = cfg or cfgmod.Config()
        self.plain_store = Store()
        self.store: Store | VaultStore = self.plain_store
        self.vault: Vault | None = Vault() if cfgmod.VAULT_META_PATH.exists() else None
        self.vault_store: VaultStore | None = None
        self.library = "notes"
        self.current: Note | None = None

        self._dirty = False
        self._loading = False
        self._refreshing = False
        self._closing = False
        self._preview_mode = False
        self._save_job: str | None = None
        self._search_job: str | None = None
        self._auto_job: str | None = None
        self._backup_running = False
        self._last_backup: datetime | None = None
        self._last_change = datetime.now()
        self._queue: queue.Queue = queue.Queue()
        self._combo_notes: list[Note] = []
        self._label_map: dict[str, Note] = {}
        self._vault_panel = None
        self._vault_intent: tuple | None = None
        self._vault_mode = "unlock"
        self._vault_busy = False
        self._vault_entries: list[ctk.CTkEntry] = []
        self._menu_cache: dict[str, MenuOverlay] = {}

        self.font_ui = ctk.CTkFont(family=FONT_FAMILY, size=13)
        self.font_small = ctk.CTkFont(family=FONT_FAMILY, size=12)
        self.font_tiny = ctk.CTkFont(family=FONT_FAMILY, size=11)
        self.font_brand = ctk.CTkFont(family=FONT_FAMILY, size=14, weight="bold")
        self.font_title = ctk.CTkFont(family=FONT_FAMILY, size=20, weight="bold")
        self.font_mono = ctk.CTkFont(family=MONO_FAMILY, size=12)

        self.title("MemoNest 便签")
        self.minsize(380, 490)
        self.configure(fg_color=PALETTE["bg"])
        self._set_icon()

        self._build_menu()
        self._build_ui()
        self._bind_shortcuts()
        self._restore_window()
        self.after(150, self._apply_native_style)

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self._startup_content()
        self._sync_autostart()
        self._schedule_auto_backup()
        self._poll_queue()
        self.set_status("就绪")

    # ------------------------------------------------------------------
    # 便签库 / 私密库
    # ------------------------------------------------------------------
    def _startup_content(self) -> None:
        welcome = self._ensure_welcome()
        notes = self.refresh_list()
        note = self.current or (notes[0] if notes else welcome)
        if note is not None:
            self.load_note(note)

    def _vault_ready(self) -> bool:
        return self.vault_store is not None

    def _ensure_vault_ready(self) -> bool:
        if self._vault_ready():
            return True
        self.open_vault_panel("unlock")
        return False

    # ------------------------------------------------------------------
    # 私密库面板：所有交互都在主窗口内完成
    # ------------------------------------------------------------------
    def open_vault_panel(self, mode: str = "unlock", intent: tuple | None = None) -> None:
        p = PALETTE
        self._close_vault_panel()
        if self.vault is None:
            mode = "create"
        self._vault_mode = mode
        self._vault_intent = intent
        self._vault_busy = False

        panel = ctk.CTkFrame(self, fg_color=p["bg"], corner_radius=0)
        panel.place(in_=self.body, relx=0, rely=0, relwidth=1, relheight=1)
        panel.lift()
        panel.bind("<Escape>", lambda _e: self._cancel_vault_panel())
        self._vault_panel = panel

        card = ctk.CTkFrame(
            panel,
            fg_color=p["card"],
            corner_radius=18,
            border_width=1,
            border_color=p["border"],
        )
        card.place(relx=0.5, rely=0.5, anchor="center", relwidth=0.86)
        inner = ctk.CTkFrame(card, fg_color="transparent", corner_radius=0)
        inner.pack(fill="both", expand=True, padx=20, pady=18)

        titles = {
            "create": (
                "🔒  创建私密笔记库",
                "只有你主动移进来的便签才会加密；其他便签仍然是 Markdown 明文。",
            ),
            "unlock": ("🔒  私密笔记库", "输入主密码，或使用 Windows Hello 解锁。"),
            "password": ("🔒  更改主密码", "更改后，Windows Hello 的快捷解锁会同步更新。"),
        }
        title, desc = titles.get(mode, titles["unlock"])
        ctk.CTkLabel(
            inner,
            text=title,
            font=ctk.CTkFont(family=FONT_FAMILY, size=16, weight="bold"),
            text_color=p["fg"],
            anchor="w",
        ).pack(fill="x")
        ctk.CTkLabel(
            inner,
            text=desc,
            font=self.font_small,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=320,
        ).pack(fill="x", pady=(2, 12))

        fields = {
            "create": [("主密码", "至少 6 位"), ("确认主密码", "再输入一次")],
            "unlock": [("主密码", "输入主密码")],
            "password": [
                ("当前主密码", "验证身份"),
                ("新主密码", "至少 6 位"),
                ("确认新主密码", "再输入一次"),
            ],
        }[mode]

        self._vault_entries: list[ctk.CTkEntry] = []
        for name, hint in fields:
            ctk.CTkLabel(
                inner,
                text=name,
                font=self.font_tiny,
                text_color=p["muted"],
                anchor="w",
            ).pack(fill="x", pady=(0, 2))
            entry = ctk.CTkEntry(
                inner,
                show="•",
                placeholder_text=hint,
                height=34,
                corner_radius=9,
                border_width=1,
                border_color=p["border"],
                fg_color=p["bg"],
                text_color=p["fg"],
                font=self.font_small,
            )
            entry.pack(fill="x", pady=(0, 8))
            entry.bind("<Return>", lambda _e: self._vault_primary())
            self._vault_entries.append(entry)

        self._vault_msg = ctk.CTkLabel(
            inner,
            text="",
            font=self.font_tiny,
            text_color="#C2503C",
            anchor="w",
            justify="left",
            wraplength=320,
        )
        self._vault_msg.pack(fill="x", pady=(0, 4))

        self._vault_primary_btn = ctk.CTkButton(
            inner,
            text={"create": "创建并解锁", "unlock": "解锁", "password": "更改密码"}[mode],
            height=34,
            corner_radius=9,
            fg_color=p["accent"],
            hover_color=p["accent_hover"],
            text_color="#3B3323",
            text_color_disabled="#6F5C20",
            font=ctk.CTkFont(family=FONT_FAMILY, size=13, weight="bold"),
            command=self._vault_primary,
        )
        self._vault_primary_btn.pack(fill="x", pady=(2, 0))

        self._vault_hello_btn = None
        if mode == "unlock" and self.vault is not None and self.vault.hello_ready():
            self._vault_hello_btn = ctk.CTkButton(
                inner,
                text="使用 Windows Hello 解锁",
                height=32,
                corner_radius=9,
                fg_color=p["strip"],
                hover_color="#EFE1A6",
                text_color=p["fg"],
                font=self.font_small,
                command=self._vault_hello,
            )
            self._vault_hello_btn.pack(fill="x", pady=(8, 0))

        self._vault_cancel_btn = ctk.CTkButton(
            inner,
            text="取消",
            height=26,
            corner_radius=8,
            fg_color="transparent",
            hover_color=p["strip"],
            text_color=p["muted"],
            font=self.font_tiny,
            command=self._cancel_vault_panel,
        )
        self._vault_cancel_btn.pack(fill="x", pady=(8, 0))

        self.after(120, self._vault_entries[0].focus_set)

    def _vault_set_busy(self, busy: bool, message: str = "") -> None:
        self._vault_busy = busy
        state = "disabled" if busy else "normal"
        for widget in (
            getattr(self, "_vault_primary_btn", None),
            getattr(self, "_vault_hello_btn", None),
            getattr(self, "_vault_cancel_btn", None),
        ):
            if widget is not None:
                widget.configure(state=state)
        if getattr(self, "_vault_msg", None) is not None:
            try:
                self._vault_msg.configure(
                    text=message,
                    text_color=PALETTE["muted"] if busy else "#C2503C",
                )
            except tk.TclError:
                pass

    def _vault_fail(self, message: str) -> None:
        self._vault_set_busy(False)
        if getattr(self, "_vault_msg", None) is not None:
            try:
                self._vault_msg.configure(text=message, text_color="#C2503C")
            except tk.TclError:
                pass

    def _vault_primary(self) -> None:
        if self._vault_busy:
            return
        values = [entry.get() for entry in self._vault_entries]
        mode = self._vault_mode
        self._vault_set_busy(True, "正在处理…")
        self.update_idletasks()

        if mode == "create":
            error = validate_new_password(values)
            if error:
                self._vault_fail(error)
                return
            ok, message = self.create_vault(values[0])
            if not ok:
                self._vault_fail(message)
                return
            self._vault_finish(True)
            return

        if mode == "unlock":
            if not values[0]:
                self._vault_fail("请输入主密码")
                return
            try:
                self.vault.unlock(values[0])
                self.vault_store = VaultStore(self.vault)
            except Exception as exc:
                self._vault_fail(str(exc))
                return
            self._vault_finish(True)
            return

        error = validate_change_password(values)
        if error:
            self._vault_fail(error)
            return
        try:
            self.vault.change_password(values[0], values[1])
        except Exception as exc:
            self._vault_fail(str(exc))
            return
        if self.library != "vault":
            self.vault_store = None
            self.vault.lock()
        self.cfg.set("general.hello_unlock", self.vault.hello_enabled())
        try:
            self.cfg.save()
        except OSError:
            LOG.exception("保存配置失败")
        self._vault_finish(True)

    def _vault_hello(self) -> None:
        if self._vault_busy or self.vault is None:
            return
        self._vault_set_busy(True, "请在 Windows 安全窗口中完成验证…")
        vault = self.vault

        def work() -> None:
            try:
                vault.unlock_hello()
                error = ""
            except Exception as exc:  # pragma: no cover - 取决于系统
                error = str(exc)
            self._post(self._vault_hello_done, error)

        threading.Thread(target=work, daemon=True).start()

    def _vault_hello_done(self, error: str) -> None:
        if error:
            if self._vault_panel is not None:
                self._vault_fail(error)
            return
        try:
            self.vault_store = VaultStore(self.vault)
        except Exception as exc:  # pragma: no cover
            LOG.exception("打开私密笔记库失败")
            if self._vault_panel is not None:
                self._vault_fail(f"打开私密笔记库失败：{exc}")
            return
        if self._vault_panel is not None:
            self._vault_finish(True)

    def _vault_finish(self, ok: bool) -> None:
        intent = self._vault_intent
        mode = getattr(self, "_vault_mode", "unlock")
        self._close_vault_panel()
        if not ok:
            self.library_tabs.set("私密" if self.library == "vault" else "便签")
            return
        if mode == "password":
            self.set_status("主密码已更新")
            return
        if intent and intent[0] == "move":
            self.move_to_vault()
            return
        select_id = intent[1] if intent and intent[0] == "switch" else None
        self._switch_library("vault", select_id)

    def _cancel_vault_panel(self) -> None:
        if self._vault_busy:
            return
        self._vault_intent = None
        self._close_vault_panel()
        self.library_tabs.set("私密" if self.library == "vault" else "便签")
        self.set_status("就绪")

    def _close_vault_panel(self) -> None:
        panel = getattr(self, "_vault_panel", None)
        self._vault_panel = None
        if panel is not None:
            try:
                panel.destroy()
            except tk.TclError:
                pass

    def create_vault(self, password: str) -> tuple[bool, str]:
        if self.vault is not None:
            return True, ""
        vault = Vault()
        try:
            vault.create(password)
            if bool(self.cfg.get("general.hello_unlock")) and hello.available():
                try:
                    vault.enable_hello()
                except Exception:
                    LOG.exception("启用 Windows Hello 快速解锁失败")
            store = VaultStore(vault)
        except Exception as exc:
            LOG.exception("创建私密笔记库失败")
            try:
                import shutil

                shutil.rmtree(vault.root, ignore_errors=True)
            except Exception:
                pass
            return False, str(exc)
        self.vault = vault
        self.vault_store = store
        self.cfg.set("general.hello_unlock", vault.hello_enabled())
        try:
            self.cfg.save()
        except OSError:
            LOG.exception("保存配置失败")
        self._build_menu()
        return True, ""

    def _on_library_tab(self, value: str) -> None:
        target = "vault" if value == "私密" else "notes"
        if self._vault_panel is not None and target == "notes":
            # 面板是覆盖在正文上的，切回「便签」时必须一并收起，
            # 否则界面看起来没有任何变化。
            if self._vault_busy:
                self.library_tabs.set("私密")
                return
            self._cancel_vault_panel()
            if self.library != "notes":
                self._switch_library("notes")
            self.library_tabs.set("便签")
            return
        if not self._switch_library(target):
            if self._vault_panel is None:
                self.library_tabs.set("私密" if self.library == "vault" else "便签")

    def _prewarm_menu(self) -> None:
        """在空闲时预先构建菜单，避免第一次点「⋯」时临时创建控件。"""
        if self._menu is not None or self._closing:
            return
        if self.library in self._menu_cache:
            return
        try:
            overlay = MenuOverlay(self, self._menu_items)
            self._menu_cache[self.library] = overlay
            # 先放到窗口外完成一次布局，之后显示时就不用再做冷布局
            overlay.place(x=-10000, y=-10000)
            self.update_idletasks()
            overlay.place_forget()
        except Exception:
            LOG.exception("预构建菜单失败")

    def _switch_library(self, target: str, select_id: str | None = None) -> bool:
        if target == self.library:
            if select_id:
                note = self.store.get(select_id)
                if note is not None:
                    self.load_note(note)
            return True
        if target == "vault":
            self.save_current(refresh=False)
            if not self._vault_ready():
                self.open_vault_panel("unlock", ("switch", select_id))
                self.library_tabs.set("私密")
                return False
            self.store = self.vault_store
            self.library = "vault"
        else:
            self.save_current(refresh=False)
            self.store = self.plain_store
            self.library = "notes"
        self._after_library_switch(select_id)
        return True

    def _after_library_switch(self, select_id: str | None = None) -> None:
        self.library_tabs.set("私密" if self.library == "vault" else "便签")
        self._build_menu()
        self._apply_library_style()
        self.current = None
        self._clear_editor()
        notes = self.refresh_list()
        target = None
        if select_id:
            target = next((n for n in notes if n.id == select_id), None)
        if target is None and notes:
            target = notes[0]
        if target is not None:
            self.load_note(target)
        self.set_status("私密笔记库 · 已解锁" if self.library == "vault" else "便签库")

    def _apply_library_style(self) -> None:
        private = self.library == "vault"
        self.title("MemoNest 便签 · 私密" if private else "MemoNest 便签")

    def move_to_vault(self) -> None:
        if self.library == "vault":
            return
        if self.current is None:
            self.set_status("请先选择一条便签")
            return
        self.save_current(refresh=False)
        if not self._vault_ready():
            self.open_vault_panel("unlock", ("move",))
            return
        note = self.current
        target = self.vault_store.create(note.title, note.content)
        target.tags = list(note.tags)
        target.pinned = note.pinned
        target.created = note.created
        self.vault_store.save(target)
        self.plain_store.delete(note.id)
        self._dirty = False
        self.store = self.vault_store
        self.library = "vault"
        self._after_library_switch(select_id=target.id)
        self.set_status("已移到私密笔记库，原明文文件已删除")

    def move_to_notes(self) -> None:
        if self.library != "vault" or self.current is None:
            return
        self.save_current(refresh=False)
        note = self.current
        target = self.plain_store.create(note.title, note.content)
        target.tags = list(note.tags)
        target.pinned = note.pinned
        target.created = note.created
        self.plain_store.save(target)
        if self.vault_store is not None:
            self.vault_store.delete(note.id)
        self._dirty = False
        self.store = self.plain_store
        self.library = "notes"
        self._after_library_switch(select_id=target.id)
        self.set_status("已移回普通便签库")

    def lock_vault(self) -> None:
        if self.vault is None or self._closing:
            return
        self._close_vault_panel()
        switched = self.library == "vault"
        if switched:
            try:
                self.save_current(refresh=False)
            except Exception:
                LOG.exception("锁定前保存失败")
            self.store = self.plain_store
            self.library = "notes"
        self.vault_store = None
        self.vault.lock()
        if switched:
            self._after_library_switch()
        self.set_status("私密笔记库已锁定")

    # ------------------------------------------------------------------
    # 菜单 / 快捷键
    # ------------------------------------------------------------------
    def _build_menu(self) -> None:
        """不再使用系统菜单栏，改为顶部「⋯」展开的卡片菜单。"""
        for overlay in getattr(self, "_menu_cache", {}).values():
            try:
                overlay.destroy()
            except tk.TclError:
                pass
        self._menu_cache = {}
        self._topmost_var = tk.BooleanVar(value=bool(self.cfg.get("general.always_on_top")))
        self._menu_items = [
            ("新建便签", "Ctrl+N", self.new_note),
            ("保存", "Ctrl+S", lambda: self.save_current(force=True)),
            ("置顶笔记", "", self.toggle_pin),
            ("预览 / 编辑", "Ctrl+E", self.toggle_preview),
            ("搜索便签", "Ctrl+F", self.focus_search),
            ("立即云备份", "F5", self.start_backup),
            ("设置…", "Ctrl+,", self.open_settings),
            (None, "", None),
            ("导出为 Markdown…", "", self.export_note),
            ("打开数据文件夹", "", lambda: self._open_path(cfgmod.DATA_DIR)),
            ("删除当前便签", "Ctrl+D", self.delete_note),
            (None, "", None),
            ("使用说明", "", self.show_help),
            ("关于 MemoNest", "", self.show_about),
            ("退出 MemoNest", "", self.on_close),
        ]
        if self.library == "vault":
            extra = [
                ("移回普通便签", "", self.move_to_notes),
                ("锁定私密笔记库", "Ctrl+L", self.lock_vault),
            ]
        else:
            extra = [("移到私密笔记库", "", self.move_to_vault)]
        index = next(
            (i for i, item in enumerate(self._menu_items) if item[0] == "设置…"),
            len(self._menu_items) - 1,
        )
        self._menu_items[index + 1:index + 1] = [(None, "", None), *extra]
        self._menu: MenuOverlay | None = None
        self.after(60, self._prewarm_menu)

    def show_menu(self) -> None:
        if self._menu is not None:
            self._menu.close()
            return
        overlay = self._menu_cache.get(self.library)
        if overlay is None:
            overlay = MenuOverlay(self, self._menu_items)
            self._menu_cache[self.library] = overlay
        self._menu = overlay
        overlay.open()

    def _bind_shortcuts(self) -> None:
        self.bind_all("<Control-n>", lambda _e: self._shortcut(self.new_note))
        self.bind_all("<Control-s>", lambda _e: self._shortcut(lambda: self.save_current(force=True)))
        self.bind_all("<Control-f>", lambda _e: self._shortcut(self.focus_search))
        self.bind_all("<Control-d>", lambda _e: self._shortcut(self.delete_note))
        self.bind_all("<Control-r>", lambda _e: self._shortcut(self.refresh_list))
        self.bind_all("<Control-Key-1>", lambda _e: self._shortcut(lambda: self.show_mode(0)))
        self.bind_all("<Control-Key-2>", lambda _e: self._shortcut(lambda: self.show_mode(1)))
        self.bind_all("<Control-e>", lambda _e: self._shortcut(self.toggle_preview))
        self.bind_all("<Control-comma>", lambda _e: self._shortcut(self.open_settings))
        self.bind_all("<Control-l>", lambda _e: self._shortcut(self.lock_vault))
        self.bind_all("<F5>", lambda _e: self._shortcut(self.start_backup))

        self.editor.bind("<Control-z>", lambda _e: self._undo())
        self.editor.bind("<Control-y>", lambda _e: self._redo())
        self.editor.bind("<Control-Z>", lambda _e: self._redo())
        self.editor.bind("<Tab>", self._insert_tab)
        self.editor.bind("<Button-3>", self._show_editor_menu)

    @staticmethod
    def _shortcut(callback):
        callback()
        return "break"

    def _editor_action(self, event_name: str) -> str:
        widget = self.preview if self._preview_mode else self.editor
        widget.event_generate(event_name)
        return "break"

    def _undo(self) -> str:
        try:
            self.editor.edit_undo()
        except tk.TclError:
            pass
        self._mark_dirty()
        return "break"

    def _redo(self) -> str:
        try:
            self.editor.edit_redo()
        except tk.TclError:
            pass
        self._mark_dirty()
        return "break"

    def _insert_tab(self, _event=None) -> str:
        self.editor.insert("insert", "    ")
        return "break"

    # ------------------------------------------------------------------
    # 界面
    # ------------------------------------------------------------------
    def _build_ui(self) -> None:
        p = PALETTE
        top = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        top.pack(fill="x", padx=14, pady=(10, 0))
        top.columnconfigure(0, weight=1)

        header = ctk.CTkFrame(top, fg_color="transparent", corner_radius=0)
        header.grid(row=0, column=0, sticky="ew")
        header.columnconfigure(1, weight=1)
        ctk.CTkLabel(header, text="MemoNest", font=self.font_brand, text_color=p["fg"]).grid(
            row=0, column=0, sticky="w"
        )
        self.library_tabs = ctk.CTkSegmentedButton(
            header,
            values=["便签", "私密"],
            command=self._on_library_tab,
            width=96,
            height=24,
            corner_radius=8,
            font=self.font_tiny,
            fg_color=p["strip"],
            selected_color="#E7CF87",
            selected_hover_color="#E7CF87",
            unselected_color=p["strip"],
            unselected_hover_color="#EFE1A6",
            text_color=p["fg"],
        )
        self.library_tabs.set("便签")
        self.library_tabs.grid(row=0, column=1, sticky="w", padx=(7, 0))

        actions = ctk.CTkFrame(header, fg_color="transparent", corner_radius=0)
        actions.grid(row=0, column=2, sticky="e")
        self._header_actions = actions
        self.preview_button = self._strip_button(actions, "预览", self.toggle_preview)
        self._strip_button(actions, "备份", self.start_backup)
        self.topmost_button = self._strip_button(actions, "置顶", self.toggle_topmost)
        self.menu_button = ctk.CTkButton(
            actions,
            text="⋯",
            width=28,
            height=25,
            corner_radius=8,
            fg_color="transparent",
            hover_color="#F1E3A9",
            text_color=p["fg"],
            font=ctk.CTkFont(family=FONT_FAMILY, size=16, weight="bold"),
            command=self.show_menu,
        )
        self.menu_button.pack(side="left", padx=(4, 0))

        selector = ctk.CTkFrame(top, fg_color="transparent", corner_radius=0)
        selector.grid(row=1, column=0, sticky="ew", pady=(9, 0))
        selector.columnconfigure(0, weight=1)
        self.note_combo = ctk.CTkComboBox(
            selector,
            values=[],
            state="readonly",
            command=self._on_combo_select,
            height=30,
            corner_radius=10,
            border_width=0,
            fg_color=p["field"],
            border_color=p["border"],
            button_color="#F0DFA0",
            button_hover_color="#E7D28A",
            dropdown_fg_color=p["card"],
            dropdown_hover_color="#F7ECBE",
            dropdown_text_color=p["fg"],
            text_color=p["fg"],
            font=self.font_small,
            dropdown_font=self.font_small,
        )
        self.note_combo.grid(row=0, column=0, sticky="ew")
        ctk.CTkButton(
            selector,
            text="+",
            width=33,
            height=30,
            corner_radius=10,
            fg_color=p["accent"],
            hover_color=p["accent_hover"],
            text_color="#3B3323",
            font=ctk.CTkFont(family=MONO_FAMILY, size=17, weight="bold"),
            command=self.new_note,
        ).grid(row=0, column=1, padx=(8, 0))

        self.search_row = ctk.CTkFrame(top, fg_color="transparent", corner_radius=0)
        self.search_row.grid(row=2, column=0, sticky="ew", pady=(7, 0))
        self.search_row.columnconfigure(0, weight=1)
        self.search_var = tk.StringVar()
        self.search_var.trace_add("write", self._on_search_change)
        self.search_entry = ctk.CTkEntry(
            self.search_row,
            textvariable=self.search_var,
            placeholder_text="搜索便签，回车打开…",
            height=28,
            corner_radius=8,
            border_width=1,
            border_color=p["border"],
            fg_color=p["card"],
            text_color=p["fg"],
            placeholder_text_color=p["muted"],
            font=self.font_small,
        )
        self.search_entry.grid(row=0, column=0, sticky="ew")
        self.search_entry.bind("<Return>", self._on_search_return)
        self.search_entry.bind("<Escape>", lambda _e: self._hide_search())
        ctk.CTkButton(
            self.search_row,
            text="Esc",
            width=40,
            height=28,
            corner_radius=8,
            fg_color="transparent",
            hover_color=p["strip"],
            text_color=p["muted"],
            font=self.font_tiny,
            command=self._hide_search,
        ).grid(row=0, column=1, padx=(6, 0))
        self.search_row.grid_remove()

        body = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        body.pack(fill="both", expand=True, padx=14, pady=(8, 12))
        self.body = body
        body.columnconfigure(0, weight=1)
        body.rowconfigure(3, weight=1)

        self.title_var = tk.StringVar()
        self.title_entry = ctk.CTkEntry(
            body,
            textvariable=self.title_var,
            placeholder_text="标题",
            font=self.font_title,
            height=42,
            corner_radius=0,
            border_width=0,
            fg_color="transparent",
            text_color=p["fg"],
            placeholder_text_color="#C9BC8C",
        )
        self.title_entry.grid(row=0, column=0, sticky="ew", pady=(6, 0))
        self.title_entry.bind("<Return>", lambda _e: self.editor.focus_set())

        meta = ctk.CTkFrame(body, fg_color="transparent", corner_radius=0)
        meta.grid(row=1, column=0, sticky="ew")
        meta.columnconfigure(1, weight=1)
        ctk.CTkLabel(meta, text="#", font=self.font_small, text_color=p["muted"], width=12).grid(
            row=0, column=0, sticky="w", padx=(2, 4)
        )
        self.tags_var = tk.StringVar()
        self.tags_entry = ctk.CTkEntry(
            meta,
            textvariable=self.tags_var,
            placeholder_text="添加标签，用逗号分隔",
            height=24,
            corner_radius=0,
            border_width=0,
            fg_color="transparent",
            text_color=p["muted"],
            placeholder_text_color="#C9BC8C",
            font=self.font_tiny,
        )
        self.tags_entry.grid(row=0, column=1, sticky="ew")
        self.meta_label = ctk.CTkLabel(
            meta, text="—", font=self.font_tiny, text_color=p["muted"], anchor="e"
        )
        self.meta_label.grid(row=0, column=2, sticky="e", padx=(8, 4))

        divider = ctk.CTkFrame(body, height=1, fg_color=p["border"], corner_radius=0)
        divider.grid(row=2, column=0, sticky="ew", pady=(8, 8))

        card = ctk.CTkFrame(
            body,
            fg_color=p["card"],
            corner_radius=14,
            border_width=1,
            border_color=p["border"],
        )
        card.grid(row=3, column=0, sticky="nsew")
        card.columnconfigure(0, weight=1)
        card.rowconfigure(0, weight=1)

        text_wrap = ctk.CTkFrame(card, fg_color="transparent", corner_radius=0)
        text_wrap.grid(row=0, column=0, sticky="nsew", padx=(12, 6), pady=10)
        text_wrap.columnconfigure(0, weight=1)
        text_wrap.rowconfigure(0, weight=1)

        text_options = dict(
            wrap="word",
            bd=0,
            highlightthickness=0,
            padx=0,
            pady=0,
            bg=p["card"],
            fg=p["fg"],
            insertbackground=p["accent"],
            selectbackground=p["selection"],
            spacing1=2,
            spacing3=4,
        )
        self.editor = tk.Text(
            text_wrap,
            undo=True,
            maxundo=-1,
            font=(FONT_FAMILY, 12),
            tabs=("2c",),
            **text_options,
        )
        self.editor.grid(row=0, column=0, sticky="nsew")
        self.editor.bind("<<Modified>>", self._on_modified)
        self.editor.bind("<KeyRelease>", lambda _e: self._update_stats())

        self.preview = tk.Text(text_wrap, **text_options)
        md_palette = {
            "bg": p["card"],
            "fg": p["fg"],
            "muted": p["muted"],
            "accent": p["link"],
            "code_bg": p["code_bg"],
            "code_fg": p["code_fg"],
            "border": p["border"],
        }
        self.md_view = MarkdownView(self.preview, md_palette, base_size=10)
        self.preview.grid_remove()

        self.edit_scroll = ctk.CTkScrollbar(
            text_wrap,
            command=self.editor.yview,
            orientation="vertical",
            width=10,
            corner_radius=6,
            fg_color="transparent",
            button_color="#E8D79E",
            button_hover_color="#DDC885",
        )
        self.edit_scroll.grid(row=0, column=1, sticky="ns", padx=(4, 0))
        self.editor.configure(yscrollcommand=self.edit_scroll.set)

        self.preview_scroll = ctk.CTkScrollbar(
            text_wrap,
            command=self.preview.yview,
            orientation="vertical",
            width=10,
            corner_radius=6,
            fg_color="transparent",
            button_color="#E8D79E",
            button_hover_color="#DDC885",
        )
        self.preview_scroll.grid(row=0, column=1, sticky="ns", padx=(4, 0))
        self.preview.configure(yscrollcommand=self.preview_scroll.set)
        self.preview_scroll.grid_remove()

        bottom = ctk.CTkFrame(body, fg_color="transparent", corner_radius=0)
        bottom.grid(row=4, column=0, sticky="ew", pady=(7, 0))
        bottom.columnconfigure(0, weight=1)
        self.status_label = ctk.CTkLabel(
            bottom, text="", font=self.font_tiny, text_color=p["muted"], anchor="w"
        )
        self.status_label.grid(row=0, column=0, sticky="w", padx=(2, 0))
        self.stats_label = ctk.CTkLabel(
            bottom, text="0 字 · 0 行", font=self.font_tiny, text_color=p["muted"], anchor="e"
        )
        self.stats_label.grid(row=0, column=1, sticky="e", padx=(0, 2))

    def _strip_button(self, parent, text: str, command) -> ctk.CTkButton:
        button = ctk.CTkButton(
            parent,
            text=text,
            width=44,
            height=25,
            corner_radius=8,
            fg_color="transparent",
            hover_color="#F1E3A9",
            text_color=PALETTE["muted"],
            font=self.font_small,
            command=command,
        )
        button.pack(side="left", padx=(2, 0))
        return button

    def _add_lock_button(self) -> None:
        """兼容旧调用：私密库入口现在是顶栏的「便签 / 私密」切换。"""
        return

    # ------------------------------------------------------------------
    # 窗口
    # ------------------------------------------------------------------
    def _set_icon(self) -> None:
        apply_icon(self)

    def _apply_native_style(self) -> None:
        winstyle.apply(self, PALETTE["bg"], PALETTE["fg"], PALETTE["border"])

    def _restore_window(self) -> None:
        geometry = str(self.cfg.get("general.window_geometry", "") or "")
        if re.fullmatch(r"\d+x\d+[+-]\d+[+-]\d+", geometry):
            self.geometry(geometry)
        else:
            width, height = 440, 640
            x = max(20, self.winfo_screenwidth() - width - 48)
            self.geometry(f"{width}x{height}+{x}+70")
        if self.cfg.get("general.always_on_top"):
            self.attributes("-topmost", True)
            self.topmost_button.configure(text="已置顶", text_color=PALETTE["fg"])

    def _apply_topmost(self) -> None:
        enabled = bool(self._topmost_var.get())
        self.attributes("-topmost", enabled)
        self.topmost_button.configure(
            text="已置顶" if enabled else "置顶",
            text_color=PALETTE["fg"] if enabled else PALETTE["muted"],
            fg_color=PALETTE["strip"] if enabled else "transparent",
        )

    def toggle_topmost(self) -> None:
        self._topmost_var.set(not bool(self._topmost_var.get()))
        self._apply_topmost()

    # ------------------------------------------------------------------
    # 笔记切换
    # ------------------------------------------------------------------
    def _ensure_welcome(self) -> Note | None:
        if self.store is None:
            return None
        if self.store.notes:
            return None
        note = self.store.create("欢迎使用 MemoNest", WELCOME)
        self.current = note
        return note

    def refresh_list(self, keep: str | None = None, select: str | None = None) -> list[Note]:
        if self.store is None:
            self._combo_notes = []
            if hasattr(self, "note_combo"):
                self.note_combo.set("")
            return []
        self._refreshing = True
        notes = self.store.filter(self.search_var.get() if hasattr(self, "search_var") else "")
        self._combo_notes = notes
        self._sync_combo()
        self._refreshing = False
        return notes

    def _sync_combo(self) -> None:
        labels: list[str] = []
        self._label_map = {}
        for note in self._combo_notes:
            base = ("★ " if note.pinned else "") + note.title
            label = base
            index = 2
            while label in self._label_map:
                label = f"{base} ({index})"
                index += 1
            self._label_map[label] = note
            labels.append(label)
        self.note_combo.configure(values=labels)
        if self.current:
            for label, note in self._label_map.items():
                if note.id == self.current.id:
                    self.note_combo.set(label)
                    return
            self.note_combo.set("")
        elif not labels:
            self.note_combo.set("")

    def _on_combo_select(self, value: str) -> None:
        if self._refreshing:
            return
        note = self._label_map.get(value)
        if note is None:
            return
        if self.current and note.id == self.current.id:
            return
        self.save_current(refresh=False)
        self.load_note(note)

    def load_note(self, note: Note) -> None:
        self._loading = True
        self.current = note
        self.title_var.set(note.title)
        self.tags_var.set(", ".join(note.tags))
        self.editor.delete("1.0", "end")
        self.editor.insert("1.0", note.content)
        self.editor.edit_reset()
        self.editor.edit_modified(False)
        self.editor.mark_set("insert", "1.0")
        self.editor.yview_moveto(0)
        self._dirty = False
        self._update_meta()
        self._update_stats()
        self._sync_combo()
        self._loading = False
        self._render_preview()
        self.set_status(f"已打开《{note.title}》")

    def _clear_editor(self) -> None:
        self._loading = True
        self.current = None
        self.title_var.set("")
        self.tags_var.set("")
        self.editor.delete("1.0", "end")
        self.editor.edit_modified(False)
        self._dirty = False
        self.meta_label.configure(text="—")
        self._update_stats()
        self.note_combo.set("")
        self._loading = False
        self._render_preview()

    def new_note(self) -> None:
        if self.store is None:
            self._need_unlock()
            return
        self.save_current(refresh=False)
        note = self.store.create("", "")
        self.refresh_list(select=note.id)
        self.load_note(note)
        self.show_mode(0)
        self.title_entry.focus_set()
        self.set_status("新建便签")

    def delete_note(self) -> None:
        if self.store is None:
            self._need_unlock()
            return
        if self.current is None:
            return
        where = "私密库的加密回收站" if self.library == "vault" else "data/trash 中找回"
        if not messagebox.askyesno(
            "删除便签",
            f"确定删除《{self.current.title}》吗？\n删除后可在 {where} 找回。",
            parent=self,
        ):
            return
        self.store.delete(self.current.id)
        self._clear_editor()
        notes = self.refresh_list()
        if notes:
            self.load_note(notes[0])
        self.set_status("已删除便签")

    def toggle_pin(self) -> None:
        if self.store is None or self.current is None:
            return
        self.save_current(refresh=False)
        self.current.pinned = not self.current.pinned
        self.store.save(self.current)
        self.refresh_list()
        self.set_status("已置顶笔记" if self.current.pinned else "已取消置顶")

    def focus_search(self) -> None:
        self.search_row.grid()
        self.search_entry.focus_set()
        self.search_entry.select_range(0, "end")

    def _on_search_change(self, *_args) -> None:
        if self._search_job:
            try:
                self.after_cancel(self._search_job)
            except Exception:
                pass
        self._search_job = self.after(200, self._apply_filter)

    def _apply_filter(self) -> None:
        self._search_job = None
        notes = self.refresh_list()
        if not notes:
            self.set_status("没有匹配的便签")
        else:
            self.set_status(f"筛选出 {len(notes)} 条，回车打开第一条")

    def _on_search_return(self, _event=None) -> str:
        if self.store is None:
            return "break"
        notes = self.store.filter(self.search_var.get())
        if notes:
            self._hide_search(load=notes[0])
        return "break"

    def _hide_search(self, load: Note | None = None) -> None:
        self.search_var.set("")
        if self._search_job:
            try:
                self.after_cancel(self._search_job)
            except Exception:
                pass
            self._search_job = None
        self.search_row.grid_remove()
        self.refresh_list()
        if load is not None:
            self.save_current(refresh=False)
            self.load_note(load)
        else:
            self.editor.focus_set()

    # ------------------------------------------------------------------
    # 保存
    # ------------------------------------------------------------------
    def _on_modified(self, _event=None) -> None:
        if self.editor.edit_modified():
            self.editor.edit_modified(False)
            if self._loading:
                return
            self._mark_dirty()

    def _on_field_change(self, _event=None) -> None:
        if self._loading:
            return
        self._mark_dirty()

    def _mark_dirty(self) -> None:
        self._dirty = True
        self._last_change = datetime.now()
        self.set_status("编辑中…")
        self._schedule_save()

    def _schedule_save(self, delay: int = 900) -> None:
        if self._save_job:
            try:
                self.after_cancel(self._save_job)
            except Exception:
                pass
        self._save_job = self.after(delay, self._autosave)

    def _autosave(self) -> None:
        self._save_job = None
        self.save_current()

    @staticmethod
    def _derive_title(content: str) -> str:
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("```"):
                continue
            if line.startswith("#"):
                candidate = line.lstrip("#").strip()
                if candidate:
                    return candidate
            return line[:60]
        return ""

    @staticmethod
    def _parse_tags(raw: str) -> list[str]:
        parts = re.split(r"[,，;；#]+", raw or "")
        tags: list[str] = []
        for part in parts:
            tag = part.strip()
            if tag and tag not in tags:
                tags.append(tag)
        return tags

    def save_current(self, force: bool = False, refresh: bool = True) -> None:
        if self.store is None or self.current is None:
            return
        if not (self._dirty or force):
            return
        content = self.editor.get("1.0", "end-1c")
        title = self.title_var.get().strip()
        if not title or title in ("未命名笔记", "无标题"):
            title = self._derive_title(content)
        self.current.title = title or "未命名笔记"
        self.current.content = content
        self.current.tags = self._parse_tags(self.tags_var.get())
        self.store.save(self.current)
        self._dirty = False
        self._last_change = datetime.now()
        self.title_var.set(self.current.title)
        self._update_meta()
        self._update_stats()
        if refresh:
            self.refresh_list()
        self._render_preview()
        self.set_status(f"已保存 · {datetime.now():%H:%M:%S}")

    # ------------------------------------------------------------------
    # 编辑 / 预览
    # ------------------------------------------------------------------
    def show_mode(self, index: int) -> None:
        self._set_mode(index == 1)

    def toggle_preview(self) -> None:
        self._set_mode(not self._preview_mode)

    def _set_mode(self, preview: bool) -> None:
        self._preview_mode = bool(preview)
        if self._preview_mode:
            self.md_view.render(self.editor.get("1.0", "end-1c"))
            self.editor.grid_remove()
            self.edit_scroll.grid_remove()
            self.preview.grid(row=0, column=0, sticky="nsew")
            self.preview_scroll.grid()
            self.preview_button.configure(text="编辑", text_color=PALETTE["fg"])
            self.preview.focus_set()
        else:
            self.preview.grid_remove()
            self.preview_scroll.grid_remove()
            self.editor.grid(row=0, column=0, sticky="nsew")
            self.edit_scroll.grid()
            self.preview_button.configure(text="预览", text_color=PALETTE["muted"])
            self.editor.focus_set()

    def _render_preview(self) -> None:
        if self._preview_mode:
            self.md_view.render(self.editor.get("1.0", "end-1c"))

    def _update_meta(self) -> None:
        if self.current is None:
            self.meta_label.configure(text="—")
            return
        self.meta_label.configure(text=f"更新于 {fmt_time(self.current.updated, short=False)}")

    def _update_stats(self) -> None:
        text = self.editor.get("1.0", "end-1c")
        chars = len(re.sub(r"\s", "", text))
        lines = text.count("\n") + 1 if text else 0
        self.stats_label.configure(text=f"{chars} 字 · {lines} 行")

    def _show_editor_menu(self, event) -> None:
        menu = tk.Menu(self, tearoff=0)
        menu.add_command(label="剪切", command=lambda: self._editor_action("<<Cut>>"))
        menu.add_command(label="复制", command=lambda: self._editor_action("<<Copy>>"))
        menu.add_command(label="粘贴", command=lambda: self._editor_action("<<Paste>>"))
        menu.add_separator()
        menu.add_command(label="全选", command=lambda: self._editor_action("<<SelectAll>>"))
        menu.add_separator()
        menu.add_command(label="插入当前时间", command=self._insert_now)
        menu.tk_popup(event.x_root, event.y_root)

    def _insert_now(self) -> None:
        self.editor.insert("insert", datetime.now().strftime("%Y-%m-%d %H:%M"))
        self._mark_dirty()

    def export_note(self) -> None:
        if self.current is None:
            messagebox.showinfo("导出", "请先选择一条便签。", parent=self)
            return
        self.save_current(refresh=False)
        safe = re.sub(r'[\\/:*?"<>|]+', "_", self.current.title) or "note"
        path = filedialog.asksaveasfilename(
            parent=self,
            title="导出 Markdown",
            initialfile=f"{safe}.md",
            defaultextension=".md",
            filetypes=[("Markdown 文件", "*.md"), ("所有文件", "*.*")],
        )
        if not path:
            return
        Path(path).write_text(self.editor.get("1.0", "end-1c"), encoding="utf-8")
        self.set_status(f"已导出到 {path}")

    # ------------------------------------------------------------------
    # 状态 / 备份
    # ------------------------------------------------------------------
    def set_status(self, text: str) -> None:
        if hasattr(self, "status_label"):
            self.status_label.configure(text=text)

    def _post(self, callback, *args, **kwargs) -> None:
        self._queue.put((callback, args, kwargs))

    def _poll_queue(self) -> None:
        if self._closing:
            return
        try:
            while True:
                callback, args, kwargs = self._queue.get_nowait()
                callback(*args, **kwargs)
        except queue.Empty:
            pass
        except Exception:
            LOG.exception("界面回调执行失败")
        self.after(120, self._poll_queue)

    def start_backup(self, silent: bool = False) -> None:
        if self.store is None:
            if not silent:
                self._need_unlock()
            return
        self.save_current(refresh=False)
        if self._backup_running:
            self.set_status("备份正在进行中…")
            return
        if not self.cfg.channels_enabled():
            if not silent and messagebox.askyesno(
                "云备份", "还没有启用 OneDrive 或 GitHub 备份。\n现在去设置吗？", parent=self
            ):
                self.open_settings()
            return
        self._backup_running = True
        self.set_status("正在云备份…")
        threading.Thread(target=self._backup_worker, args=(silent,), daemon=True).start()

    def _backup_worker(self, silent: bool) -> None:
        try:
            report = backup.run_backup(self.cfg)
        except Exception as exc:  # pragma: no cover
            LOG.exception("备份异常")
            self._post(self._backup_done, None, exc, silent)
            return
        self._post(self._backup_done, report, None, silent)

    def _backup_done(self, report, error, silent: bool) -> None:
        self._backup_running = False
        if error is not None:
            self.set_status("备份失败")
            if not silent:
                messagebox.showerror("云备份失败", str(error), parent=self)
            return
        assert report is not None
        clouds = report.cloud_steps
        if clouds and all(step.ok for step in clouds):
            self._last_backup = datetime.now()
        self.set_status("云备份完成" if report.ok else "云备份部分失败")
        if not silent:
            dialog = messagebox.showinfo if report.ok else messagebox.showwarning
            dialog("云备份", report.summary(), parent=self)

    def _schedule_auto_backup(self) -> None:
        if self._auto_job:
            try:
                self.after_cancel(self._auto_job)
            except Exception:
                pass
            self._auto_job = None
        minutes = int(self.cfg.get("general.auto_backup_minutes", 0) or 0)
        if minutes > 0 and self.cfg.channels_enabled():
            self._auto_job = self.after(minutes * 60 * 1000, self._auto_backup_tick)

    def _auto_backup_tick(self) -> None:
        self._auto_job = None
        if self._last_backup is None or self._last_change > self._last_backup:
            self.start_backup(silent=True)
        self._schedule_auto_backup()

    # ------------------------------------------------------------------
    # 设置 / 其他
    # ------------------------------------------------------------------
    def _sync_autostart(self) -> None:
        if not autostart.supported():
            return
        want = bool(self.cfg.get("general.autostart"))
        try:
            if want and not autostart.is_enabled():
                autostart.enable()
            elif not want and autostart.is_enabled():
                autostart.disable()
        except OSError:
            LOG.exception("同步开机自启失败")

    def open_settings(self) -> None:
        SettingsDialog(self)

    def _need_unlock(self) -> None:
        messagebox.showinfo("私密笔记库", "请先解锁私密笔记库。", parent=self)

    def _open_path(self, path: Path) -> None:
        try:
            if path.suffix and not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("", encoding="utf-8")
            os.startfile(str(path))
        except OSError as exc:
            messagebox.showerror("打开失败", str(exc), parent=self)

    def show_help(self) -> None:
        tip = (
            "· 顶栏「便签 / 私密」切换普通与私密库，Ctrl+L 锁定私密库\n"
            if self.vault is not None
            else "· 笔记文件位于 data/notes，可直接用其他编辑器编辑\n"
        )
        messagebox.showinfo(
            "使用说明",
            "MemoNest 便签\n\n"
            "· 顶部下拉框切换便签，「＋」新建\n"
            "· 标题与正文自动保存，Ctrl+S 手动保存\n"
            "· 「预览」查看 Markdown 效果，Ctrl+E 切换\n"
            "· 「置顶」让便签窗口始终最前\n"
            "· Ctrl+F 搜索 / Ctrl+D 删除 / F5 云备份\n"
            f"{tip}"
            "· 私密库里的便签加密保存，其余便签仍是 Markdown 明文\n"
            "· OneDrive 备份可用同步文件夹，或直接登录 Microsoft 账号\n"
            "· GitHub 备份需要 Personal Access Token（repo 权限）",
            parent=self,
        )

    def show_about(self) -> None:
        messagebox.showinfo(
            "关于",
            f"{cfgmod.APP_NAME}  v{cfgmod.APP_VERSION}\n\n"
            "便签式的本地 Markdown 备忘录。\n"
            "CustomTkinter 界面 · OneDrive 云备份 · GitHub 同步\n"
            "可选私密笔记库（主密码 + Windows Hello）\n\n"
            f"数据目录：{cfgmod.DATA_DIR}",
            parent=self,
        )

    def on_close(self) -> None:
        if self._closing:
            return
        self._closing = True
        try:
            self.save_current(refresh=False)
        except Exception:
            LOG.exception("退出前保存失败")

        try:
            self.cfg.set("general.window_geometry", self.geometry())
            self.cfg.set("general.always_on_top", bool(self.attributes("-topmost")))
            self.cfg.save()
        except OSError:
            LOG.exception("保存窗口状态失败")

        needs_backup = (
            bool(self.cfg.get("general.backup_on_exit"))
            and self.cfg.channels_enabled()
            and (self._last_backup is None or self._last_change > self._last_backup)
        )
        if needs_backup:
            self.set_status("正在退出前备份…")
            try:
                self.update_idletasks()
                worker = threading.Thread(target=self._exit_backup, daemon=True)
                worker.start()
                worker.join(timeout=20)
            except Exception:
                LOG.exception("退出前备份失败")
        if self.vault is not None:
            try:
                self.vault.lock()
            except Exception:
                LOG.exception("锁定私密库失败")
        self.destroy()

    def _exit_backup(self) -> None:
        try:
            backup.run_backup(self.cfg)
        except Exception:
            LOG.exception("退出前备份失败")


class MenuOverlay(ctk.CTkFrame):
    """窗口内展开的卡片菜单，紧跟「⋯」按钮，视觉与便签一致。

    菜单第一次打开时构建并缓存，之后只显示 / 隐藏。CustomTkinter 每次新建
    几十个控件要几百毫秒，缓存后展开基本是即时的。
    """

    def __init__(self, app: "MemoApp", items) -> None:
        p = PALETTE
        super().__init__(
            app,
            fg_color=p["card"],
            corner_radius=12,
            border_width=1,
            border_color=p["border"],
            width=214,
        )
        self.app = app
        self._closed = True
        self._click_bind: str | None = None
        self._esc_bind: str | None = None

        for label, shortcut, command in items:
            if label is None:
                tk.Frame(self, height=1, bg=p["border"]).pack(fill="x", padx=10, pady=3)
                continue
            row = tk.Frame(self, bg=p["card"], cursor="hand2")
            row.pack(fill="x", padx=5, pady=1)
            row.grid_columnconfigure(0, weight=1)
            name = tk.Label(
                row,
                text=label,
                anchor="w",
                font=app.font_small,
                fg=p["fg"],
                bg=p["card"],
                padx=0,
                pady=2,
                cursor="hand2",
            )
            name.grid(row=0, column=0, sticky="ew", padx=(9, 4))
            hint = tk.Label(
                row,
                text=shortcut,
                anchor="e",
                font=app.font_tiny,
                fg=p["muted"],
                bg=p["card"],
                padx=0,
                pady=2,
                cursor="hand2",
            )
            hint.grid(row=0, column=1, sticky="e", padx=(4, 9))

            def enter(_event=None, widgets=(row, name, hint)):
                for widget in widgets:
                    widget.configure(bg=p["strip"])

            def leave(_event=None, widgets=(row, name, hint)):
                for widget in widgets:
                    widget.configure(bg=p["card"])

            def choose(_event=None, callback=command):
                self.close()
                callback()

            for widget in (row, name, hint):
                widget.bind("<Enter>", enter)
                widget.bind("<Leave>", leave)
                widget.bind("<Button-1>", choose)

    def open(self) -> None:
        self._closed = False
        self.place(relx=1.0, y=46, x=-12, anchor="ne")
        self.lift()
        self._click_bind = self.app.bind("<Button-1>", self._on_app_click, add="+")
        self._esc_bind = self.app.bind("<Escape>", self._on_escape, add="+")

    def _on_app_click(self, event) -> None:
        widget = event.widget
        try:
            if str(widget).startswith(str(self.app.menu_button)):
                return
        except Exception:
            pass
        while widget is not None:
            if widget is self:
                return
            widget = getattr(widget, "master", None)
        self.close()

    def _on_escape(self, _event=None) -> None:
        self.close()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._click_bind is not None:
            try:
                self.app.unbind("<Button-1>", self._click_bind)
            except tk.TclError:
                pass
            self._click_bind = None
        if self._esc_bind is not None:
            try:
                self.app.unbind("<Escape>", self._esc_bind)
            except tk.TclError:
                pass
            self._esc_bind = None
        self.place_forget()
        if self.app._menu is self:
            self.app._menu = None


class SettingsDialog(ctk.CTkToplevel):
    """设置窗口：通用 / OneDrive / GitHub。"""

    def __init__(self, app: MemoApp) -> None:
        super().__init__(app)
        self.app = app
        self.cfg = app.cfg
        self.vars: dict[str, tk.Variable] = {}
        self.title("MemoNest 设置")
        self.geometry("700x680")
        self.minsize(640, 560)
        self.configure(fg_color=PALETTE["bg"])
        self.transient(app)
        apply_icon(self)
        self._build()
        self.grab_set()
        self.bind("<Escape>", lambda _e: self._cancel())
        self.bind("<Map>", self._on_map, add="+")
        self.protocol("WM_DELETE_WINDOW", self._cancel)
        self.after(150, self._style_frame)
        self.after(700, self._style_frame)
        self.after(1500, self._style_frame)
        self.focus_set()

    def _on_map(self, event=None) -> None:
        if event is None or event.widget is self:
            self.after(60, self._style_frame)

    def _style_frame(self) -> None:
        winstyle.apply(self, PALETTE["bg"], PALETTE["fg"], PALETTE["border"])

    def _build(self) -> None:
        p = PALETTE
        wrapper = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        wrapper.pack(fill="both", expand=True, padx=16, pady=14)

        ctk.CTkLabel(
            wrapper, text="设置", font=ctk.CTkFont(family=FONT_FAMILY, size=19, weight="bold"),
            text_color=p["fg"],
        ).pack(anchor="w", pady=(0, 6))

        self.nb = ctk.CTkTabview(
            wrapper,
            fg_color=p["card"],
            corner_radius=12,
            border_width=1,
            border_color=p["border"],
            segmented_button_fg_color=p["strip"],
            segmented_button_selected_color="#E7CF87",
            segmented_button_selected_hover_color="#E7CF87",
            segmented_button_unselected_color=p["strip"],
            segmented_button_unselected_hover_color="#EFE1A6",
            text_color=p["fg"],
        )
        self.nb.pack(fill="both", expand=True, pady=(4, 10))

        for name in ("通用", "私密库", "OneDrive", "GitHub"):
            self.nb.add(name)
            scroll = ctk.CTkScrollableFrame(
                self.nb.tab(name), fg_color="transparent", corner_radius=0
            )
            scroll.pack(fill="both", expand=True, padx=6, pady=6)
            scroll.columnconfigure(1, weight=1)
            try:
                scroll._scrollbar.configure(
                    fg_color="transparent",
                    button_color="#E8D79E",
                    button_hover_color="#DDC885",
                )
            except Exception:  # pragma: no cover - CTk 内部实现变化
                pass
            if name == "通用":
                self._build_general(scroll)
            elif name == "私密库":
                self.vault_frame = scroll
                self._build_vault(scroll)
            elif name == "OneDrive":
                self._build_onedrive(scroll)
            else:
                self._build_github(scroll)

        buttons = ctk.CTkFrame(wrapper, fg_color="transparent", corner_radius=0)
        buttons.pack(fill="x")
        ctk.CTkButton(
            buttons,
            text="保存",
            width=96,
            height=34,
            corner_radius=9,
            fg_color=p["accent"],
            hover_color=p["accent_hover"],
            text_color="#3B3323",
            font=ctk.CTkFont(family=FONT_FAMILY, size=13, weight="bold"),
            command=self._save,
        ).pack(side="right")
        ctk.CTkButton(
            buttons,
            text="取消",
            width=80,
            height=34,
            corner_radius=9,
            fg_color="transparent",
            hover_color=p["strip"],
            text_color=p["fg"],
            border_width=1,
            border_color=p["border"],
            command=self._cancel,
        ).pack(side="right", padx=(0, 8))

    def _field(
        self,
        parent,
        row: int,
        label: str,
        key: str,
        kind: str = "str",
        show: str | None = None,
        hint: str | None = None,
        width: int | None = None,
        folder: bool = False,
    ) -> tk.Variable:
        p = PALETTE
        ctk.CTkLabel(
            parent, text=label, font=self.app.font_ui, text_color=p["fg"], anchor="w"
        ).grid(row=row, column=0, sticky="w", padx=(4, 12), pady=(10, 2))

        if kind == "bool":
            var = tk.BooleanVar(value=bool(self.cfg.get(key)))
            ctk.CTkSwitch(
                parent,
                text="",
                variable=var,
                width=46,
                height=24,
                corner_radius=12,
                fg_color="#E8D9A8",
                progress_color=p["accent"],
                button_color="#FFFDF2",
                button_hover_color="#FFF8E0",
            ).grid(row=row, column=1, sticky="w", pady=(10, 2))
            self.vars[key] = var
            return var

        raw = self.cfg.get(key)
        var = tk.StringVar(value="" if raw is None else str(raw))
        self.vars[key] = var
        entry_options = dict(
            textvariable=var,
            height=32,
            corner_radius=8,
            border_width=1,
            border_color=p["border"],
            fg_color=p["card"],
            text_color=p["fg"],
            font=self.app.font_small,
        )
        if show:
            entry_options["show"] = show
        if folder:
            holder = ctk.CTkFrame(parent, fg_color="transparent", corner_radius=0)
            holder.grid(row=row, column=1, sticky="ew", pady=(10, 2))
            holder.columnconfigure(0, weight=1)
            ctk.CTkEntry(holder, **entry_options).grid(row=0, column=0, sticky="ew")
            ctk.CTkButton(
                holder,
                text="检测",
                width=52,
                height=32,
                corner_radius=8,
                fg_color=p["strip"],
                hover_color="#EFE1A6",
                text_color=p["fg"],
                font=self.app.font_tiny,
                command=lambda: self._detect_folder(var),
            ).grid(row=0, column=1, padx=(6, 0))
            ctk.CTkButton(
                holder,
                text="浏览",
                width=52,
                height=32,
                corner_radius=8,
                fg_color=p["strip"],
                hover_color="#EFE1A6",
                text_color=p["fg"],
                font=self.app.font_tiny,
                command=lambda: self._pick_folder(var),
            ).grid(row=0, column=2, padx=(6, 0))
        else:
            entry = ctk.CTkEntry(parent, **entry_options)
            if width:
                entry.configure(width=width)
            entry.grid(row=row, column=1, sticky="w" if width else "ew", pady=(10, 2))

        if hint:
            ctk.CTkLabel(
                parent,
                text=hint,
                font=self.app.font_tiny,
                text_color=p["muted"],
                anchor="w",
                justify="left",
                wraplength=460,
            ).grid(row=row + 1, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 4))
        return var

    def _build_general(self, frame) -> None:
        self._field(frame, 0, "开机自动启动", "general.autostart", "bool")
        self._field(
            frame, 1, "退出时自动云备份", "general.backup_on_exit", "bool",
            hint="检测到有改动且已启用云备份通道时，退出前会执行一次备份。",
        )
        self._field(
            frame, 3, "定时备份（分钟）", "general.auto_backup_minutes", width=90,
            hint="0 表示关闭定时备份；建议 30～120 分钟。",
        )
        self._field(
            frame, 5, "本地保留备份数", "general.keep_backups", width=90,
            hint="data/backups 中保留的 zip 数量，旧的会自动清理。",
        )
        ctk.CTkLabel(
            frame,
            text="提示：开机自启写入当前用户的注册表 Run 项，可在任务管理器的“启动”中查看。",
            font=self.app.font_tiny,
            text_color=PALETTE["muted"],
            anchor="w",
            justify="left",
            wraplength=460,
        ).grid(row=7, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(16, 6))

        actions = ctk.CTkFrame(frame, fg_color="transparent", corner_radius=0)
        actions.grid(row=8, column=0, columnspan=2, sticky="w", padx=(4, 0), pady=(2, 4))
        ctk.CTkButton(
            actions,
            text="创建桌面快捷方式",
            height=32,
            corner_radius=8,
            fg_color=PALETTE["strip"],
            hover_color="#EFE1A6",
            text_color=PALETTE["fg"],
            font=self.app.font_small,
            command=self._create_shortcut,
        ).pack(side="left")

        ctk.CTkLabel(
            frame,
            text="快捷方式与开机自启都用 pythonw 启动，不会出现黑色终端窗口。",
            font=self.app.font_tiny,
            text_color=PALETTE["muted"],
            anchor="w",
            justify="left",
            wraplength=460,
        ).grid(row=9, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(6, 4))

    _MODE_LABELS = {
        "folder": "文件夹（OneDrive 客户端）",
        "graph": "Microsoft 账号（免客户端）",
    }

    def _build_onedrive(self, frame) -> None:
        p = PALETTE
        self._field(frame, 0, "启用 OneDrive 备份", "onedrive.enabled", "bool")

        ctk.CTkLabel(
            frame, text="同步方式", font=self.app.font_ui, text_color=p["fg"], anchor="w"
        ).grid(row=1, column=0, sticky="w", padx=(4, 12), pady=(12, 2))
        mode = str(self.cfg.get("onedrive.mode", "folder") or "folder")
        self._mode_value = "graph" if mode == "graph" else "folder"
        self._mode_var = tk.StringVar(value=self._MODE_LABELS[self._mode_value])
        ctk.CTkOptionMenu(
            frame,
            values=list(self._MODE_LABELS.values()),
            variable=self._mode_var,
            command=self._mode_changed,
            height=32,
            corner_radius=8,
            fg_color=p["field"],
            button_color="#F0DFA0",
            button_hover_color="#E7D28A",
            text_color=p["fg"],
            font=self.app.font_small,
            dropdown_fg_color=p["card"],
            dropdown_text_color=p["fg"],
            dropdown_hover_color="#F7ECBE",
        ).grid(row=1, column=1, sticky="w", pady=(12, 2))

        ctk.CTkLabel(
            frame,
            text="选「文件夹」需要电脑上安装并登录 OneDrive 客户端；"
                 "选「Microsoft 账号」则直接登录账号上传，不用客户端。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=470,
        ).grid(row=2, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 6))

        # ---------------- 文件夹模式 ----------------
        folder = ctk.CTkFrame(frame, fg_color="transparent", corner_radius=0)
        folder.grid(row=3, column=0, columnspan=2, sticky="ew")
        folder.columnconfigure(1, weight=1)
        self.folder_frame = folder

        detected = cfgmod.detect_onedrive_dir()
        hint = (
            f"自动检测到：{detected}，留空即使用该目录。"
            if detected
            else "未检测到 OneDrive 文件夹，请安装并登录 OneDrive 客户端，或手动选择路径。"
        )
        self._field(folder, 0, "OneDrive 文件夹", "onedrive.folder", folder=True, hint=hint)
        self._field(
            folder, 2, "备份子文件夹", "onedrive.subfolder",
            hint="备份包与笔记会放在 OneDrive 下的这个目录中，由客户端自动上传。",
        )
        self._field(
            folder, 4, "同步笔记文件", "onedrive.mirror_notes", "bool",
            hint="开启后会把笔记镜像一份到云端目录，方便手机或其他设备查看。",
        )
        self._field(
            folder, 6, "云端保留备份数", "onedrive.keep_backups", width=90,
            hint="OneDrive 备份目录中保留的 zip 数量。",
        )
        folder_actions = ctk.CTkFrame(folder, fg_color="transparent", corner_radius=0)
        folder_actions.grid(row=8, column=0, columnspan=2, sticky="w", padx=(4, 0), pady=(14, 4))
        for text, command in (("立即同步", self._sync_onedrive), ("打开备份文件夹", self._open_onedrive)):
            ctk.CTkButton(
                folder_actions,
                text=text,
                height=32,
                corner_radius=8,
                fg_color=p["strip"],
                hover_color="#EFE1A6",
                text_color=p["fg"],
                font=self.app.font_small,
                command=command,
            ).pack(side="left", padx=(0, 8))

        # ---------------- Microsoft 账号模式 ----------------
        graph = ctk.CTkFrame(frame, fg_color="transparent", corner_radius=0)
        graph.grid(row=3, column=0, columnspan=2, sticky="ew")
        graph.columnconfigure(1, weight=1)
        self.graph_frame = graph

        self._field(
            graph, 0, "应用程序（客户端）ID", "onedrive.client_id",
            hint="在 Azure 门户免费注册一个应用后复制「应用程序(客户端) ID」。"
                 "注册时账户类型选「个人 Microsoft 账户」，并在「身份验证」中"
                 "允许公共客户端流。",
        )
        self._field(
            graph, 2, "租户", "onedrive.tenant",
            hint="一般保持 common；只有企业/学校账号需要填租户 ID 或域名。",
        )

        ctk.CTkLabel(
            graph, text="登录状态", font=self.app.font_ui, text_color=p["fg"], anchor="w"
        ).grid(row=4, column=0, sticky="w", padx=(4, 12), pady=(12, 2))
        self.od_status = ctk.CTkLabel(
            graph, text="", font=self.app.font_small, text_color=p["muted"], anchor="w"
        )
        self.od_status.grid(row=4, column=1, sticky="w", pady=(12, 2))

        graph_actions = ctk.CTkFrame(graph, fg_color="transparent", corner_radius=0)
        graph_actions.grid(row=5, column=0, columnspan=2, sticky="w", padx=(4, 0), pady=(10, 4))
        ctk.CTkButton(
            graph_actions,
            text="登录 Microsoft 账号",
            height=32,
            corner_radius=8,
            fg_color=p["accent"],
            hover_color=p["accent_hover"],
            text_color="#3B3323",
            font=self.app.font_small,
            command=self._login_onedrive,
        ).pack(side="left", padx=(0, 8))
        ctk.CTkButton(
            graph_actions,
            text="退出登录",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=self._logout_onedrive,
        ).pack(side="left", padx=(0, 8))
        ctk.CTkButton(
            graph_actions,
            text="立即同步",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=self._sync_onedrive,
        ).pack(side="left", padx=(0, 8))

        ctk.CTkButton(
            graph,
            text="打开 Azure 应用注册页",
            height=28,
            corner_radius=8,
            fg_color="transparent",
            hover_color=p["strip"],
            text_color=p["link"],
            font=self.app.font_tiny,
            command=lambda: webbrowser.open(
                "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"
            ),
        ).grid(row=6, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(2, 4))

        ctk.CTkLabel(
            frame,
            text="登录令牌只保存在本地 config.json，不会上传。私密库里的便签"
                 "在云端只有密文和包裹后的密钥，没有主密码无法还原。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=470,
        ).grid(row=4, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(10, 6))

        self._refresh_onedrive_status()
        self._apply_mode_visibility()

    def _mode_changed(self, value: str) -> None:
        for key, label in self._MODE_LABELS.items():
            if label == value:
                self._mode_value = key
                break
        self._mode_var.set(self._MODE_LABELS[self._mode_value])
        self._apply_mode_visibility()

    def _apply_mode_visibility(self) -> None:
        if self._mode_value == "graph":
            self.folder_frame.grid_remove()
            self.graph_frame.grid()
        else:
            self.graph_frame.grid_remove()
            self.folder_frame.grid()

    def _refresh_onedrive_status(self) -> None:
        if not hasattr(self, "od_status"):
            return
        if onedrive.is_logged_in(self.cfg):
            account = str(self.cfg.get("onedrive.account", "") or "")
            self.od_status.configure(
                text=f"已登录：{account}" if account else "已登录",
                text_color="#4F7A3A",
            )
        else:
            self.od_status.configure(text="未登录", text_color=PALETTE["muted"])

    def _build_vault(self, frame) -> None:
        p = PALETTE
        for child in frame.winfo_children():
            child.destroy()
        vault = self.app.vault
        exists = vault is not None
        unlocked = self.app.vault_store is not None
        if not exists:
            status, color = "未创建", p["muted"]
        elif unlocked:
            status, color = "已创建 · 当前已解锁", "#4F7A3A"
        else:
            status, color = "已创建 · 当前已锁定", p["muted"]

        ctk.CTkLabel(
            frame,
            text="私密笔记库",
            font=ctk.CTkFont(family=FONT_FAMILY, size=15, weight="bold"),
            text_color=p["fg"],
            anchor="w",
        ).grid(row=0, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(8, 2))
        ctk.CTkLabel(
            frame,
            text=status,
            font=self.app.font_small,
            text_color=color,
            anchor="w",
        ).grid(row=1, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 6))
        ctk.CTkLabel(
            frame,
            text="只有你主动「移到私密笔记库」的便签才会加密（AES-256-GCM）。"
                 "它们会保存为 data/vault/items/*.mdenc，文件名不含标题；"
                 "其他普通便签仍然是 Markdown 明文，可以照常搜索和编辑。"
                 "在顶栏把「便签 / 私密」切到私密，输入主密码或使用 Windows Hello 即可查看。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=470,
        ).grid(row=2, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 10))

        if not exists:
            ctk.CTkButton(
                frame,
                text="创建私密笔记库…",
                height=34,
                corner_radius=9,
                fg_color=p["accent"],
                hover_color=p["accent_hover"],
                text_color="#3B3323",
                font=ctk.CTkFont(family=FONT_FAMILY, size=13, weight="bold"),
                command=self._create_vault,
            ).grid(row=3, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(2, 8))
            ctk.CTkLabel(
                frame,
                text="创建时设置的主密码无法找回；Windows Hello 只是本机的快捷解锁方式。"
                     "启用后不会动你现有的明文便签。",
                font=self.app.font_tiny,
                text_color="#B4552F",
                anchor="w",
                justify="left",
                wraplength=470,
            ).grid(row=4, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 6))
            return

        hello_ok = hello.available()
        self.hello_var = tk.BooleanVar(value=bool(vault.hello_enabled()))
        ctk.CTkLabel(
            frame, text="Windows Hello 快速解锁", font=self.app.font_ui,
            text_color=p["fg"], anchor="w",
        ).grid(row=3, column=0, sticky="w", padx=(4, 12), pady=(4, 2))
        ctk.CTkSwitch(
            frame,
            text="",
            variable=self.hello_var,
            command=self._toggle_hello,
            width=46,
            height=24,
            corner_radius=12,
            fg_color="#E8D9A8",
            progress_color=p["accent"],
            button_color="#FFFDF2",
            button_hover_color="#FFF8E0",
            state="normal" if hello_ok else "disabled",
        ).grid(row=3, column=1, sticky="w", pady=(4, 2))
        ctk.CTkLabel(
            frame,
            text=(
                "本机 Windows Hello 可用。开启后，锁定状态可直接用指纹 / 人脸 / PIN 解锁；"
                "解锁密钥由 DPAPI 绑定当前 Windows 账号，不会上传到云端。"
                if hello_ok
                else "本机暂不可用（未设置 Windows Hello 或系统策略禁用），只能使用主密码。"
            ),
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=470,
        ).grid(row=4, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(0, 8))

        actions = ctk.CTkFrame(frame, fg_color="transparent", corner_radius=0)
        actions.grid(row=5, column=0, columnspan=2, sticky="w", padx=(4, 0), pady=(6, 4))
        ctk.CTkButton(
            actions,
            text="更改主密码…",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=self._change_password,
        ).pack(side="left", padx=(0, 8))
        ctk.CTkButton(
            actions,
            text="立即锁定",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=self._lock_now,
        ).pack(side="left", padx=(0, 8))
        ctk.CTkButton(
            actions,
            text="打开私密库目录",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=lambda: self.app._open_path(cfgmod.VAULT_DIR),
        ).pack(side="left")

        ctk.CTkLabel(
            frame,
            text="备份时：普通便签以 .md、私密便签以 .mdenc 上传，并附上不含本机密钥的 vault.json；"
                 "Windows Hello 的 DPAPI 密钥不会离开这台电脑。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=470,
        ).grid(row=6, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(10, 6))

    def _refresh_vault_tab(self) -> None:
        frame = getattr(self, "vault_frame", None)
        if frame is not None and frame.winfo_exists():
            self._build_vault(frame)

    def _create_vault(self) -> None:
        if self.app.vault is not None:
            self.destroy()
            self.app.open_vault_panel("unlock")
            return
        self.destroy()
        self.app.open_vault_panel("create")

    def _toggle_hello(self) -> None:
        vault = self.app.vault
        if vault is None:
            return
        want = bool(self.hello_var.get())
        if want and not self.app._vault_ready():
            self.hello_var.set(False)
            self.app.set_status("请先解锁私密笔记库，再开启 Windows Hello")
            return
        try:
            if want:
                vault.enable_hello()
            else:
                vault.disable_hello()
        except Exception as exc:
            self.hello_var.set(not want)
            self.app.set_status(f"Windows Hello：{exc}")
            return
        self.cfg.set("general.hello_unlock", want)
        try:
            self.cfg.save()
        except OSError:
            LOG.exception("保存 Hello 设置失败")
        self._refresh_vault_tab()

    def _change_password(self) -> None:
        if self.app.vault is None:
            return
        self.destroy()
        self.app.open_vault_panel("password")

    def _lock_now(self) -> None:
        self.destroy()
        self.app.lock_vault()

    def _create_shortcut(self) -> None:
        try:
            target = shortcut.create_desktop_shortcut()
        except Exception as exc:
            messagebox.showerror("创建快捷方式", str(exc), parent=self)
            return
        messagebox.showinfo("创建快捷方式", f"已创建：\n{target}", parent=self)

    def _build_github(self, frame) -> None:
        p = PALETTE
        self._field(frame, 0, "启用 GitHub 备份", "github.enabled", "bool")
        self._field(
            frame, 1, "仓库（用户名/仓库名）", "github.repo",
            hint="例如 octocat/memo-notes。仓库需已存在；空仓库也可以。",
        )
        self._field(frame, 3, "分支", "github.branch")
        self._field(
            frame, 4, "Personal Access Token", "github.token", show="•",
            hint="在 GitHub → Settings → Developer settings 生成，勾选 repo 权限即可。Token 仅保存在本地 config.json。",
        )
        self._field(frame, 6, "作者名", "github.author_name")
        self._field(frame, 8, "提交邮箱", "github.author_email")

        actions = ctk.CTkFrame(frame, fg_color="transparent", corner_radius=0)
        actions.grid(row=10, column=0, columnspan=2, sticky="w", padx=(4, 0), pady=(16, 4))
        ctk.CTkButton(
            actions,
            text="立即推送",
            height=32,
            corner_radius=8,
            fg_color=p["strip"],
            hover_color="#EFE1A6",
            text_color=p["fg"],
            font=self.app.font_small,
            command=self._push_github,
        ).pack(side="left")

        ctk.CTkLabel(
            frame,
            text="笔记以 Markdown 文件推送到仓库根目录，可直接在 GitHub 网页上浏览历史版本。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=460,
        ).grid(row=11, column=0, columnspan=2, sticky="w", padx=(4, 4), pady=(12, 6))

    def _pick_folder(self, var: tk.StringVar) -> None:
        path = filedialog.askdirectory(parent=self, initialdir=var.get() or str(Path.home()))
        if path:
            var.set(path)

    def _detect_folder(self, var: tk.StringVar) -> None:
        detected = cfgmod.detect_onedrive_dir()
        if detected:
            var.set(str(detected))
        else:
            messagebox.showwarning("自动检测", "未找到 OneDrive 文件夹，请手动选择。", parent=self)

    def _collect(self) -> None:
        numeric = {
            "general.auto_backup_minutes": 0,
            "general.keep_backups": 1,
            "onedrive.keep_backups": 1,
        }
        for key, var in self.vars.items():
            value = var.get()
            if key in numeric:
                try:
                    value = max(numeric[key], int(str(value).strip() or 0))
                except ValueError:
                    value = numeric[key]
            self.cfg.set(key, value)
        if hasattr(self, "_mode_value"):
            self.cfg.set("onedrive.mode", self._mode_value)

    def _save(self) -> None:
        self._collect()
        try:
            self.cfg.save()
        except OSError as exc:
            messagebox.showerror("保存失败", str(exc), parent=self)
            return
        try:
            autostart.set_enabled(bool(self.cfg.get("general.autostart")))
        except Exception as exc:
            messagebox.showwarning("开机自启", f"写入注册表失败：{exc}", parent=self)
        self.app._schedule_auto_backup()
        self.app.set_status("设置已保存")
        self.destroy()

    def _cancel(self) -> None:
        self.cfg.load()
        self.destroy()

    def _run_async(self, label: str, task) -> None:
        self.app.set_status(f"{label}…")

        def worker() -> None:
            try:
                detail = task()
                self.app._post(self._show_result, label, True, str(detail))
            except Exception as exc:
                LOG.exception("%s 失败", label)
                self.app._post(self._show_result, label, False, str(exc))

        threading.Thread(target=worker, daemon=True).start()

    def _show_result(self, label: str, ok: bool, detail: str) -> None:
        self.app.set_status(label + ("完成" if ok else "失败"))
        dialog = messagebox.showinfo if ok else messagebox.showerror
        dialog(label, detail, parent=self.app)

    def _sync_onedrive(self) -> None:
        self._collect()
        cfg = self.cfg
        cfgmod.ensure_dirs()

        def task() -> str:
            if str(cfg.get("onedrive.mode", "folder")) == "graph" and not onedrive.is_logged_in(cfg):
                raise RuntimeError("尚未登录 Microsoft 账号，请先点「登录 Microsoft 账号」。")
            zip_path = backup.create_zip_for(cfg)
            return backup.sync_onedrive(cfg, zip_path)

        self._run_async("OneDrive 同步", task)

    def _login_onedrive(self) -> None:
        self._collect()
        client_id = str(self.cfg.get("onedrive.client_id", "") or "").strip()
        if not client_id:
            messagebox.showwarning(
                "OneDrive 登录",
                "请先填写 Azure 应用的「应用程序（客户端）ID」。\n"
                "可点下方「打开 Azure 应用注册页」免费注册。",
                parent=self,
            )
            return
        tenant = str(self.cfg.get("onedrive.tenant", "common") or "common").strip()
        self.app.set_status("正在获取登录代码…")
        self.update_idletasks()
        try:
            flow = onedrive.start_device_flow(client_id, tenant)
        except Exception as exc:
            self.app.set_status("OneDrive 登录失败")
            messagebox.showerror("OneDrive 登录", str(exc), parent=self)
            return

        stop = threading.Event()
        dialog = DeviceCodeDialog(self.app, flow, on_closed=stop.set)
        self._login_dialog = dialog
        device_code = str(flow.get("device_code", ""))
        interval = int(flow.get("interval", 5) or 5)
        expires = int(flow.get("expires_in", 900) or 900)

        def worker() -> None:
            try:
                payload = onedrive.poll_device_token(
                    client_id, tenant, device_code, interval, expires,
                    should_stop=stop.is_set,
                )
                onedrive.save_tokens(self.cfg, payload)
                name = onedrive.get_profile(self.cfg)
                if name:
                    self.cfg.set("onedrive.account", name)
                    self.cfg.save()
            except Exception as exc:
                self.app._post(self._login_failed, str(exc), dialog)
                return
            self.app._post(self._login_ok, name, dialog)

        threading.Thread(target=worker, daemon=True).start()

    def _login_ok(self, name: str, dialog) -> None:
        self.app.set_status("OneDrive 已登录")
        if dialog is not None and dialog.winfo_exists():
            dialog.succeed(name)
        try:
            if not self.winfo_exists():
                return
        except tk.TclError:
            return
        self._refresh_onedrive_status()

    def _login_failed(self, message: str, dialog) -> None:
        self.app.set_status("OneDrive 登录失败")
        try:
            if dialog is not None and dialog.winfo_exists():
                dialog.fail(message)
        except tk.TclError:
            pass

    def _logout_onedrive(self) -> None:
        if not messagebox.askyesno("退出登录", "确定退出 Microsoft 账号登录吗？", parent=self):
            return
        onedrive.logout(self.cfg)
        self._refresh_onedrive_status()
        self.app.set_status("已退出 OneDrive 登录")

    def _push_github(self) -> None:
        self._collect()
        if not str(self.cfg.get("github.repo", "") or "").strip():
            messagebox.showwarning("GitHub", "请先填写仓库，格式为 用户名/仓库名。", parent=self)
            return
        self._run_async("GitHub 推送", lambda: backup.push_to_github(self.cfg))

    def _open_onedrive(self) -> None:
        self._collect()
        if str(self.cfg.get("onedrive.mode", "folder")) == "graph":
            webbrowser.open("https://onedrive.live.com/")
            return
        try:
            target = backup.resolve_onedrive_folder(self.cfg) / str(
                self.cfg.get("onedrive.subfolder", "MemoNest备份")
            )
            target.mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            messagebox.showerror("打开失败", str(exc), parent=self)
            return
        try:
            os.startfile(str(target))
        except OSError as exc:
            messagebox.showerror("打开失败", str(exc), parent=self)


class DeviceCodeDialog(ctk.CTkToplevel):
    """显示 Microsoft 设备代码，等待浏览器授权。"""

    def __init__(self, app: MemoApp, flow: dict, on_closed=None) -> None:
        super().__init__(app)
        self.app = app
        self.on_closed = on_closed
        self._closed = False
        self._code = str(flow.get("user_code") or "")
        self._uri = str(flow.get("verification_uri") or "https://microsoft.com/devicelogin")
        p = PALETTE
        self.title("登录 Microsoft 账号")
        self.geometry("440x360")
        self.resizable(False, False)
        self.configure(fg_color=p["bg"])
        self.transient(app)
        apply_icon(self)
        self.protocol("WM_DELETE_WINDOW", self._close)

        wrap = ctk.CTkFrame(self, fg_color="transparent", corner_radius=0)
        wrap.pack(fill="both", expand=True, padx=20, pady=18)
        ctk.CTkLabel(
            wrap,
            text="登录 Microsoft 账号",
            font=ctk.CTkFont(family=FONT_FAMILY, size=15, weight="bold"),
            text_color=p["fg"],
            anchor="w",
        ).pack(anchor="w")
        ctk.CTkLabel(
            wrap,
            text="浏览器已打开授权页。确认页面上的代码与下面一致，登录后回到这里等待完成。",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=390,
        ).pack(anchor="w", pady=(4, 10))

        self.code_label = ctk.CTkLabel(
            wrap,
            text=self._code,
            font=ctk.CTkFont(family=MONO_FAMILY, size=26, weight="bold"),
            text_color=p["fg"],
            fg_color=p["card"],
            corner_radius=10,
            height=58,
        )
        self.code_label.pack(fill="x")

        ctk.CTkButton(
            wrap,
            text="复制代码并打开浏览器",
            height=32,
            corner_radius=9,
            fg_color=p["accent"],
            hover_color=p["accent_hover"],
            text_color="#3B3323",
            font=self.app.font_small,
            command=self._open,
        ).pack(fill="x", pady=(10, 0))

        self.status = ctk.CTkLabel(
            wrap,
            text="正在打开浏览器…",
            font=self.app.font_tiny,
            text_color=p["muted"],
            anchor="w",
            justify="left",
            wraplength=390,
        )
        self.status.pack(anchor="w", pady=(10, 0))

        self.cancel_button = ctk.CTkButton(
            wrap,
            text="取消",
            height=28,
            corner_radius=8,
            fg_color="transparent",
            hover_color=p["strip"],
            text_color=p["muted"],
            border_width=1,
            border_color=p["border"],
            font=self.app.font_tiny,
            command=self._close,
        )
        self.cancel_button.pack(fill="x", side="bottom", pady=(10, 0))

        self.after(120, self._style)
        self.after(220, self._open)
        self.grab_set()

    def _style(self) -> None:
        winstyle.apply(self, PALETTE["bg"], PALETTE["fg"], PALETTE["border"])

    def _open(self) -> None:
        try:
            self.clipboard_clear()
            self.clipboard_append(self._code)
        except tk.TclError:
            pass
        try:
            webbrowser.open(self._uri)
        except Exception:  # pragma: no cover
            pass
        self.status.configure(
            text=f"已复制代码。若浏览器没有打开，请手动访问 {self._uri}", text_color=PALETTE["muted"]
        )

    def succeed(self, name: str) -> None:
        self.status.configure(
            text=f"登录成功{'：' + name if name else ''}，正在同步登录状态…",
            text_color="#4F7A3A",
        )
        self.cancel_button.configure(text="关闭")
        self.after(900, self._close)

    def fail(self, message: str) -> None:
        self.status.configure(text=message, text_color="#C2503C")
        self.cancel_button.configure(text="关闭")

    def _close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self.grab_release()
        except tk.TclError:
            pass
        if self.on_closed is not None:
            try:
                self.on_closed()
            except Exception:
                pass
        self.destroy()


def enable_dpi_awareness() -> None:
    """声明 per-monitor v2 DPI 感知。

    CustomTkinter 默认只做 SetProcessDpiAwareness(2)，非客户区（标题栏）在
    多显示器切换缩放比例时不会重新缩放。这里优先使用 v2 上下文，
    失败时保持 CustomTkinter 的默认行为。
    """
    if os.name != "nt":
        return
    try:
        import ctypes

        # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == -4
        if ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            return
    except Exception:
        LOG.debug("SetProcessDpiAwarenessContext 不可用", exc_info=True)
    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        LOG.debug("SetProcessDpiAwareness 不可用", exc_info=True)


def main() -> None:
    enable_dpi_awareness()
    setup_logging()
    cfgmod.ensure_dirs()
    LOG.info("启动 %s v%s", cfgmod.APP_NAME, cfgmod.APP_VERSION)
    app = MemoApp()
    app.mainloop()


if __name__ == "__main__":
    main()
