"""配置与路径常量。

配置保存在项目根目录的 config.json（已加入 .gitignore，不会上传到 GitHub）。
"""

from __future__ import annotations

import copy
import json
import os
import sys
from pathlib import Path
from typing import Any

APP_NAME = "MemoNest 备忘录"
APP_VERSION = "1.3.0"

FROZEN = bool(getattr(sys, "frozen", False))

if FROZEN:
    # 打包成 exe 后，配置与数据放在 exe 旁边；只读资源从解包目录读取
    APP_ROOT = Path(sys.executable).resolve().parent
    BUNDLE_DIR = Path(getattr(sys, "_MEIPASS", APP_ROOT))
else:
    APP_ROOT = Path(__file__).resolve().parent.parent
    BUNDLE_DIR = APP_ROOT

ICON_PATH = BUNDLE_DIR / "assets" / "icon.ico"
CONFIG_PATH = APP_ROOT / "config.json"

DATA_DIR = APP_ROOT / "data"
NOTES_DIR = DATA_DIR / "notes"
TRASH_DIR = DATA_DIR / "trash"
BACKUP_DIR = DATA_DIR / "backups"
VAULT_DIR = DATA_DIR / "vault"
VAULT_ITEMS_DIR = VAULT_DIR / "items"
VAULT_TRASH_DIR = VAULT_DIR / "trash"
VAULT_META_PATH = VAULT_DIR / "vault.json"
INDEX_PATH = DATA_DIR / "index.json"
LOG_PATH = DATA_DIR / "memo.log"

DEFAULTS: dict[str, Any] = {
    "onedrive": {
        "enabled": False,
        "mode": "folder",
        "folder": "",
        "subfolder": "MemoNest备份",
        "mirror_notes": True,
        "keep_backups": 30,
        "client_id": "",
        "tenant": "common",
        "access_token": "",
        "refresh_token": "",
        "expires_at": 0,
        "account": "",
    },
    "github": {
        "enabled": False,
        "repo": "",
        "branch": "main",
        "token": "",
        "remote_url": "",
        "author_name": "MemoNest",
        "author_email": "memonest@localhost",
    },
    "general": {
        "autostart": False,
        "auto_backup_minutes": 0,
        "backup_on_exit": True,
        "keep_backups": 20,
        "window_geometry": "",
        "always_on_top": False,
        "hello_unlock": True,
    },
}


def ensure_dirs() -> None:
    """创建数据目录（可重复调用）。"""
    for path in (DATA_DIR, NOTES_DIR, TRASH_DIR, BACKUP_DIR):
        path.mkdir(parents=True, exist_ok=True)


def _merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _merge(base[key], value)
        else:
            base[key] = value
    return base


class Config:
    """点号路径访问的配置对象，例如 cfg.get("outlook.username")。"""

    def __init__(self, path: Path | None = None) -> None:
        self.path = Path(path) if path else CONFIG_PATH
        self.data: dict[str, Any] = copy.deepcopy(DEFAULTS)
        self.load()

    # ---- 读写 ----
    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raw = {}
        if isinstance(raw, dict):
            self.data = _merge(copy.deepcopy(DEFAULTS), raw)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(self.data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        os.replace(tmp, self.path)

    # ---- 访问 ----
    def get(self, dotted: str, default: Any = None) -> Any:
        current: Any = self.data
        for part in dotted.split("."):
            if not isinstance(current, dict) or part not in current:
                return default
            current = current[part]
        return current

    def set(self, dotted: str, value: Any) -> None:
        parts = dotted.split(".")
        current = self.data
        for part in parts[:-1]:
            node = current.get(part)
            if not isinstance(node, dict):
                node = {}
                current[part] = node
            current = node
        current[parts[-1]] = value

    def section(self, name: str) -> dict[str, Any]:
        node = self.data.get(name)
        if not isinstance(node, dict):
            node = {}
            self.data[name] = node
        return node

    def channels_enabled(self) -> bool:
        return bool(self.get("onedrive.enabled") or self.get("github.enabled"))


def detect_onedrive_dir() -> Path | None:
    """自动查找本机 OneDrive 同步文件夹。"""
    candidates: list[Path] = []
    for env in ("OneDrive", "OneDriveConsumer", "OneDriveCommercial"):
        value = os.environ.get(env)
        if value:
            candidates.append(Path(value))

    home = Path.home()
    candidates.extend([home / "OneDrive", home / "OneDrive - Personal"])
    try:
        candidates.extend(p for p in home.glob("OneDrive*") if p.is_dir())
    except OSError:
        pass

    seen: set[str] = set()
    for path in candidates:
        try:
            key = str(path.resolve()).lower()
        except OSError:
            key = str(path).lower()
        if key in seen:
            continue
        seen.add(key)
        try:
            if path.is_dir():
                return path
        except OSError:
            continue
    return None
