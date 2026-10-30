"""跨版本互通验证（Python 侧）。

用法：
    python tools/xcompat.py make   <dir>     # 建库 + 写一条笔记
    python tools/xcompat.py verify <dir>     # 读回全部笔记，检查有没有 Flutter 写的
    python tools/xcompat.py dump   <dir>     # 只打印内容
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import vault as vaultmod  # noqa: E402

PASSWORD = "xcompat-pass-123"


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    action, root = sys.argv[1], Path(sys.argv[2])

    vault = vaultmod.Vault(root)
    if action == "make":
        if vault.exists():
            print("VAULT-EXISTS")
        else:
            vault.create(PASSWORD)
        store = vaultmod.VaultStore(vault)
        note = store.create(title="来自 Python", content="Python 写的私密内容")
        store.save(note)
        print(f"PY-WROTE id={note.id}")
        return 0

    if not vault.exists():
        print("NO-VAULT")
        return 1
    vault.unlock(PASSWORD)
    store = vaultmod.VaultStore(vault)
    notes = store.all_notes()
    print(f"PY-READ count={len(notes)}")
    for note in notes:
        print(f"PY-NOTE id={note.id} title={note.title} content={note.content!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
