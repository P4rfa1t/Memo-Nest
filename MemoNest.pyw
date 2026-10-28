#!/usr/bin/env pythonw
"""MemoNest 无控制台启动器：双击本文件即可，不会弹出终端窗口。

如果你习惯双击 app.py，请改用本文件（.pyw 由 pythonw 打开）；
也可以从再下一行的兼容逻辑看到：找不到依赖时会用对话框提示，而不是闪退。
"""

from __future__ import annotations

import runpy
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))


def _alert(message: str) -> None:
    try:
        import ctypes

        ctypes.windll.user32.MessageBoxW(None, message, "MemoNest", 0x10)
    except Exception:
        pass


try:
    runpy.run_path(str(ROOT / "app.py"), run_name="__main__")
except SystemExit as exc:
    if exc.code not in (None, 0):
        _alert(str(exc.code))
except Exception:
    _alert("MemoNest 启动失败：\n\n" + traceback.format_exc(limit=4))
