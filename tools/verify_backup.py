"""跨版本备份互通验证（Python 侧）。

读回 Flutter 版打出的 zip 与 OneDrive 目录同步结果，确认包内布局、
文件名前缀、vault.json 的字段都与 Python 版一致。

用法：
    python tools/verify_backup.py <flutter-root>
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = Path(sys.argv[1])
    data = root / "data"
    backups = sorted((data / "backups").glob("memo-backup-*.zip"))
    if not backups:
        print("NO-BACKUP")
        return 1
    latest = backups[-1]
    print(f"PY-ZIP {latest.name} {latest.stat().st_size}")

    with zipfile.ZipFile(latest) as archive:
        names = sorted(archive.namelist())
        print(f"PY-ENTRIES {names}")
        assert any(n.startswith("notes/") and n.endswith(".md") for n in names), "缺 notes/*.md"
        assert "index.json" in names, "缺 index.json"
        assert "vault/vault.json" in names, "缺 vault/vault.json"
        assert any(n.startswith("vault/items/") for n in names), "缺 vault/items/*"

        meta = json.loads(archive.read("vault/vault.json").decode("utf-8"))
        assert "dpapi_key" not in meta, "vault.json 里不该有 dpapi_key"
        assert isinstance(meta.get("key_tag"), str), "vault.json 缺 key_tag"
        print(f"PY-META keys={sorted(meta)}")

        for name in names:
            if not name.startswith("notes/"):
                continue
            text = archive.read(name).decode("utf-8")
            print(f"PY-NOTE {name} plain={'这是明文内容' in text} secret={'这是密文内容' in text}")

    mirror = root / "onedrive" / "MemoNest备份"
    if not mirror.exists():
        print("NO-MIRROR")
        return 1
    notes = sorted((mirror / "notes").glob("*.md"))
    items = sorted((mirror / "vault" / "items").glob("*.mdenc"))
    print(f"PY-MIRROR notes={len(notes)} items={len(items)}")
    assert (mirror / "index.json").exists(), "镜像缺 index.json"
    meta = json.loads((mirror / "vault" / "vault.json").read_text(encoding="utf-8"))
    assert "dpapi_key" not in meta, "镜像 vault.json 里不该有 dpapi_key"
    plain = "\n".join(f.read_text(encoding="utf-8") for f in notes)
    assert "这是明文内容" in plain, "明文笔记内容不对"
    assert "这是密文内容" not in plain, "私密内容泄露到明文镜像"
    print("PY-OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
