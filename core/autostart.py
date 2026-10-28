"""Windows 开机自启：写入 HKCU 的 Run 注册表项（Unicode 安全，无需快捷方式）。"""

from __future__ import annotations

import os
import sys
from pathlib import Path

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE_NAME = "MemoNest"
APP_ROOT = Path(__file__).resolve().parent.parent
APP_SCRIPT = APP_ROOT / "app.py"


def _pythonw() -> str:
    """优先使用同目录下的 pythonw（无控制台）；找不到才退回当前解释器。"""
    executable = Path(sys.executable)
    name = executable.name.lower()
    if name.endswith("w.exe"):
        return str(executable)
    if name.endswith(".exe"):
        candidate = executable.with_name(executable.name[:-4] + "w.exe")
        if candidate.exists():
            return str(candidate)
    for fallback in ("pythonw.exe", "python3w.exe"):
        candidate = executable.with_name(fallback)
        if candidate.exists():
            return str(candidate)
    return str(executable)


def launch_command() -> str:
    """返回带引号的启动命令，供注册表使用。"""
    return f'"{_pythonw()}" "{APP_SCRIPT}"'


def supported() -> bool:
    return os.name == "nt"


def is_enabled() -> bool:
    if not supported():
        return False
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            value, _ = winreg.QueryValueEx(key, VALUE_NAME)
    except (FileNotFoundError, OSError):
        return False
    return str(value) == launch_command()


def enable() -> None:
    if not supported():
        raise RuntimeError("开机自启仅支持 Windows")
    import winreg

    with winreg.CreateKeyEx(
        winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE
    ) as key:
        winreg.SetValueEx(key, VALUE_NAME, 0, winreg.REG_SZ, launch_command())


def disable() -> None:
    if not supported():
        return
    import winreg

    try:
        with winreg.OpenKey(
            winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE
        ) as key:
            winreg.DeleteValue(key, VALUE_NAME)
    except FileNotFoundError:
        pass


def set_enabled(enabled: bool) -> None:
    if enabled:
        enable()
    else:
        disable()
