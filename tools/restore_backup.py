"""把 Flutter 版打出的备份包还原成 Python 版能打开的私密库。

用法：
    python tools/restore_backup.py <zip> <target-data-dir> [password]

验证的是「换版本不丢数据」这条承诺：Flutter 打的包，Python 解回去后
能用原密码解锁、读到全部私密笔记。
"""

from __future__ import annotations

import shutil
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import vault as vaultmod  # noqa: E402


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    archive_path = Path(sys.argv[1])
    target = Path(sys.argv[2])
    password = sys.argv[3] if len(sys.argv) > 3 else "backup-pass-123"

    if target.exists():
        shutil.rmtree(target)
    (target / "notes").mkdir(parents=True)
    (target / "trash").mkdir(parents=True)
    (target / "vault" / "items").mkdir(parents=True)

    with zipfile.ZipFile(archive_path) as archive:
        for name in archive.namelist():
            dest = target / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(archive.read(name))

    vault = vaultmod.Vault(target / "vault")
    if not vault.exists():
        print("NO-VAULT")
        return 1
    vault.unlock(password)
    store = vaultmod.VaultStore(vault)
    notes = store.all_notes()
    print(f"PY-UNLOCKED count={len(notes)}")
    for note in notes:
        print(f"PY-VAULT-NOTE id={note.id} title={note.title} content={note.content!r}")

    plain = sorted((target / "notes").glob("*.md"))
    print(f"PY-PLAIN count={len(plain)}")
    for note_file in plain:
        print(f"PY-PLAIN-NOTE {note_file.name}")
    print("PY-RESTORE-OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
