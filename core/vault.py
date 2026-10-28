"""加密笔记库：主密码 + Windows Hello 快速解锁，笔记逐条 AES-256-GCM 加密。

设计要点
- 库密钥（32 字节随机数）只存在内存里，落盘时用主密码派生的 KEK 包裹。
- 每条笔记单独加密成 data/vault/items/<id>.mdenc，文件名不含标题。
- 云端备份上传的只有密文 + 包裹后的密钥，没有主密码无法还原。
- 「Windows Hello 快速解锁」把库密钥再用 DPAPI 包一层（绑定当前 Windows 账号），
  使用前必须先通过 Hello 验证，换电脑或换账号后自动失效。
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
import uuid
from datetime import datetime
from pathlib import Path

from . import config as cfgmod
from . import crypto, dpapi, hello
from .storage import Note, iso_now

LOG = logging.getLogger("memonest.vault")

AAD_NOTE = b"memonest-note-v1"


class VaultError(RuntimeError):
    """加密库操作失败（口令错误、未登录等）。"""


class Vault:
    """管理 vault.json 与库密钥。"""

    def __init__(self, root: Path | None = None) -> None:
        self.root = Path(root or cfgmod.VAULT_DIR)
        self.meta_path = self.root / "vault.json"
        self.items_dir = self.root / "items"
        self.trash_dir = self.root / "trash"
        self.key: bytes | None = None

    # ---------- 元数据 ----------
    def exists(self) -> bool:
        return self.meta_path.exists()

    def meta(self) -> dict:
        try:
            return json.loads(self.meta_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}

    def _save_meta(self, meta: dict) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.meta_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self.meta_path)

    @staticmethod
    def _key_tag(key: bytes) -> str:
        return hashlib.sha256(b"memonest-key-tag" + key).hexdigest()[:16]

    # ---------- 创建 / 解锁 ----------
    def create(self, password: str) -> None:
        if self.exists():
            raise VaultError("加密库已存在")
        if len(password or "") < 6:
            raise VaultError("主密码至少 6 位，建议 10 位以上")
        salt = crypto.new_salt()
        kek = crypto.derive(password, salt)
        key = crypto.new_key()
        meta = {
            "version": 1,
            "kdf": {
                "name": "scrypt",
                "salt": crypto.b64e(salt),
                "n": crypto.SCRYPT_N,
                "r": crypto.SCRYPT_R,
                "p": crypto.SCRYPT_P,
            },
            "wrapped_key": crypto.b64e(crypto.encrypt(kek, key, crypto.AAD_META)),
            "key_tag": self._key_tag(key),
            "created": iso_now(),
        }
        self.root.mkdir(parents=True, exist_ok=True)
        self.items_dir.mkdir(parents=True, exist_ok=True)
        self.trash_dir.mkdir(parents=True, exist_ok=True)
        self._save_meta(meta)
        self.key = key

    def _kek(self, password: str, meta: dict) -> bytes:
        kdf = meta.get("kdf") or {}
        try:
            salt = crypto.b64d(str(kdf["salt"]))
        except (KeyError, ValueError) as exc:
            raise VaultError("vault.json 已损坏") from exc
        return crypto.derive(
            password,
            salt,
            int(kdf.get("n", crypto.SCRYPT_N)),
            int(kdf.get("r", crypto.SCRYPT_R)),
            int(kdf.get("p", crypto.SCRYPT_P)),
        )

    def unlock(self, password: str) -> None:
        meta = self.meta()
        if not meta:
            raise VaultError("找不到加密库")
        kek = self._kek(password, meta)
        try:
            key = crypto.decrypt(kek, crypto.b64d(meta["wrapped_key"]), crypto.AAD_META)
        except (KeyError, ValueError, crypto.CryptoError) as exc:
            raise VaultError("主密码不正确") from exc
        if meta.get("key_tag") and self._key_tag(key) != meta["key_tag"]:
            raise VaultError("密钥校验失败，vault.json 可能被替换")
        self.key = key

    def lock(self) -> None:
        self.key = None

    @property
    def unlocked(self) -> bool:
        return self.key is not None

    # ---------- Windows Hello ----------
    def hello_enabled(self) -> bool:
        return bool(self.meta().get("dpapi_key"))

    def hello_ready(self) -> bool:
        return self.hello_enabled() and hello.available()

    def enable_hello(self) -> None:
        if self.key is None:
            raise VaultError("请先解锁加密库")
        if not hello.available():
            raise VaultError("此设备暂不支持 Windows Hello")
        meta = self.meta()
        meta["dpapi_key"] = crypto.b64e(dpapi.protect(self.key))
        self._save_meta(meta)

    def disable_hello(self) -> None:
        meta = self.meta()
        if "dpapi_key" in meta:
            meta.pop("dpapi_key")
            self._save_meta(meta)

    def unlock_hello(self) -> None:
        meta = self.meta()
        if not meta.get("dpapi_key"):
            raise VaultError("尚未在本机启用 Windows Hello 解锁")
        ok, message = hello.verify()
        if not ok:
            raise VaultError(message)
        try:
            key = dpapi.unprotect(crypto.b64d(meta["dpapi_key"]))
        except (ValueError, OSError) as exc:
            raise VaultError(str(exc)) from exc
        if meta.get("key_tag") and self._key_tag(key) != meta["key_tag"]:
            raise VaultError("Windows Hello 保存的密钥已失效，请用主密码解锁")
        self.key = key

    # ---------- 修改主密码 ----------
    def change_password(self, old: str, new: str) -> None:
        self.unlock(old)
        if len(new or "") < 6:
            raise VaultError("新密码至少 6 位")
        meta = self.meta()
        salt = crypto.new_salt()
        kek = crypto.derive(new, salt)
        meta["kdf"] = {
            "name": "scrypt",
            "salt": crypto.b64e(salt),
            "n": crypto.SCRYPT_N,
            "r": crypto.SCRYPT_R,
            "p": crypto.SCRYPT_P,
        }
        meta["wrapped_key"] = crypto.b64e(crypto.encrypt(kek, self.key, crypto.AAD_META))
        if meta.get("dpapi_key"):
            meta["dpapi_key"] = crypto.b64e(dpapi.protect(self.key))
        self._save_meta(meta)

    # ---------- 迁移明文笔记 ----------
    def migrate(self, notes) -> int:
        if self.key is None:
            raise VaultError("请先解锁加密库")
        self.items_dir.mkdir(parents=True, exist_ok=True)
        count = 0
        for note in notes:
            target = self.items_dir / f"{note.id}.mdenc"
            target.write_bytes(_seal_note(self.key, note))
            count += 1
        return count

    def migrate_trash(self, trash_dir: Path | None = None) -> int:
        """把明文回收站里的 .md 加密后放进来，避免遗留可读副本。"""
        if self.key is None:
            raise VaultError("请先解锁加密库")
        source = Path(trash_dir or cfgmod.TRASH_DIR)
        if not source.is_dir():
            return 0
        self.trash_dir.mkdir(parents=True, exist_ok=True)
        count = 0
        for path in sorted(source.glob("*.md")):
            target = self.trash_dir / f"{path.name}.mdenc"
            try:
                target.write_bytes(
                    crypto.encrypt(self.key, path.read_bytes(), b"memonest-trash-v1")
                )
                path.unlink()
            except OSError:
                LOG.warning("无法加密回收站文件 %s", path.name)
                continue
            count += 1
        return count


def _seal_note(key: bytes, note: Note) -> bytes:
    payload = note.to_dict()
    payload["content"] = note.content
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return crypto.encrypt(key, data, AAD_NOTE + note.id.encode("utf-8"))


def _open_note(key: bytes, blob: bytes, note_id: str) -> dict:
    data = crypto.decrypt(key, blob, AAD_NOTE + note_id.encode("utf-8"))
    return json.loads(data.decode("utf-8"))


class VaultStore:
    """与 Store 相同的接口，把笔记读写换成加密文件。"""

    def __init__(self, vault: Vault) -> None:
        if vault.key is None:
            raise VaultError("加密库尚未解锁")
        self.vault = vault
        self.notes_dir = vault.items_dir
        self.trash_dir = vault.trash_dir
        self.notes: dict[str, Note] = {}
        self.notes_dir.mkdir(parents=True, exist_ok=True)
        self.trash_dir.mkdir(parents=True, exist_ok=True)
        self.load()

    def load(self) -> None:
        self.notes.clear()
        key = self.vault.key
        assert key is not None
        for path in sorted(self.notes_dir.glob("*.mdenc")):
            note_id = path.stem
            try:
                payload = _open_note(key, path.read_bytes(), note_id)
            except Exception:
                LOG.warning("无法解密笔记文件 %s", path.name)
                continue
            note = Note.from_dict(payload)
            note.id = note_id
            note.content = str(payload.get("content", ""))
            note.filename = path.name
            self.notes[note.id] = note

    def save_index(self) -> None:  # 加密库不落盘明文索引
        return

    # ---------- CRUD ----------
    def create(self, title: str = "", content: str = "") -> Note:
        note = Note(
            id=uuid.uuid4().hex[:12],
            title=title.strip() or "未命名笔记",
            content=content,
        )
        self.save(note)
        return note

    def save(self, note: Note) -> Note:
        key = self.vault.key
        if key is None:
            raise VaultError("加密库已锁定")
        note.title = note.title.strip() or "未命名笔记"
        note.updated = iso_now()
        note.filename = f"{note.id}.mdenc"
        tmp = self.notes_dir / f".{note.id}.tmp"
        tmp.write_bytes(_seal_note(key, note))
        os.replace(tmp, self.notes_dir / note.filename)
        self.notes[note.id] = note
        return note

    def delete(self, note_id: str) -> bool:
        note = self.notes.pop(note_id, None)
        if note is None:
            return False
        source = self.notes_dir / note.filename
        if source.exists():
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            try:
                shutil.move(str(source), str(self.trash_dir / f"{note_id}-{stamp}.mdenc"))
            except OSError:
                LOG.warning("无法移动加密笔记到回收站")
        return True

    def get(self, note_id: str) -> Note | None:
        return self.notes.get(note_id)

    # ---------- 查询 ----------
    def all_notes(self) -> list[Note]:
        return sorted(
            self.notes.values(),
            key=lambda n: (n.pinned, n.updated),
            reverse=True,
        )

    def filter(self, query: str = "", tag: str | None = None) -> list[Note]:
        query = (query or "").strip().lower()
        notes = self.all_notes()
        if tag:
            notes = [n for n in notes if tag in n.tags]
        if not query:
            return notes
        return [
            n
            for n in notes
            if query
            in f"{n.title}\n{' '.join(n.tags)}\n{n.content}".lower()
        ]

    def all_tags(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for note in self.notes.values():
            for tag in note.tags:
                counts[tag] = counts.get(tag, 0) + 1
        return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
