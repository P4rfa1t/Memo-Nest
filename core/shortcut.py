"""桌面快捷方式：指向 pythonw.exe，双击时不出现控制台窗口。"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from . import config as cfgmod

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _pythonw() -> Path:
    executable = Path(sys.executable)
    name = executable.name.lower()
    if name.endswith("w.exe"):
        return executable
    if name.endswith(".exe"):
        candidate = executable.with_name(executable.name[:-4] + "w.exe")
        if candidate.exists():
            return candidate
    for fallback in ("pythonw.exe", "python3w.exe"):
        candidate = executable.with_name(fallback)
        if candidate.exists():
            return candidate
    return executable


def desktop_dir() -> Path:
    try:
        import ctypes

        buffer = ctypes.create_unicode_buffer(260)
        ctypes.windll.shell32.SHGetFolderPathW(None, 0x10, None, 0, buffer)
        if buffer.value:
            return Path(buffer.value)
    except Exception:  # pragma: no cover - 非 Windows
        pass
    return Path.home() / "Desktop"


def create_desktop_shortcut(name: str = "MemoNest") -> Path:
    if sys.platform != "win32":
        raise RuntimeError("仅支持 Windows")
    pythonw = _pythonw()
    script = cfgmod.APP_ROOT / "app.py"
    icon = cfgmod.APP_ROOT / "assets" / "icon.ico"
    target = desktop_dir() / f"{name}.lnk"
    target.parent.mkdir(parents=True, exist_ok=True)

    command = (
        "$w=New-Object -ComObject WScript.Shell;"
        f"$s=$w.CreateShortcut('{target}');"
        f"$s.TargetPath='{pythonw}';"
        f"$s.Arguments='\"{script}\"';"
        f"$s.WorkingDirectory='{cfgmod.APP_ROOT}';"
        f"$s.IconLocation='{icon}';"
        "$s.Description='MemoNest 便签备忘录';"
        "$s.Save()"
    )
    process = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=CREATE_NO_WINDOW,
    )
    if process.returncode != 0:
        detail = (process.stderr or process.stdout or "").strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "创建快捷方式失败")
    return target
