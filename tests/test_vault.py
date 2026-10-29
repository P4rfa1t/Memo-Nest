"""私密笔记库测试：加密往返、库操作、密文备份与云端镜像。"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from core import backup, crypto  # noqa: E402
from core import config as cfgmod  # noqa: E402
from core.storage import Store  # noqa: E402
from core.vault import Vault, VaultStore, VaultError  # noqa: E402

PATH_NAMES = (
    "DATA_DIR",
    "NOTES_DIR",
    "TRASH_DIR",
    "BACKUP_DIR",
    "VAULT_DIR",
    "VAULT_ITEMS_DIR",
    "VAULT_TRASH_DIR",
    "VAULT_META_PATH",
    "INDEX_PATH",
    "CONFIG_PATH",
)


def _patch_paths(base: Path) -> dict[str, Path]:
    data = base / "data"
    paths = {
        "DATA_DIR": data,
        "NOTES_DIR": data / "notes",
        "TRASH_DIR": data / "trash",
        "BACKUP_DIR": data / "backups",
        "VAULT_DIR": data / "vault",
        "VAULT_ITEMS_DIR": data / "vault" / "items",
        "VAULT_TRASH_DIR": data / "vault" / "trash",
        "VAULT_META_PATH": data / "vault" / "vault.json",
        "INDEX_PATH": data / "index.json",
        "CONFIG_PATH": base / "config.json",
    }
    for name, value in paths.items():
        setattr(cfgmod, name, value)
    cfgmod.ensure_dirs()
    return paths


class CryptoPrimitiveTests(unittest.TestCase):
    def test_roundtrip_and_wrong_key(self) -> None:
        key = crypto.new_key()
        blob = crypto.encrypt(key, "机密内容".encode("utf-8"), b"aad")
        self.assertEqual(crypto.decrypt(key, blob, b"aad").decode("utf-8"), "机密内容")
        with self.assertRaises(crypto.CryptoError):
            crypto.decrypt(crypto.new_key(), blob, b"aad")
        with self.assertRaises(crypto.CryptoError):
            crypto.decrypt(key, blob, b"other")

    def test_derive_is_deterministic(self) -> None:
        salt = crypto.new_salt()
        self.assertEqual(crypto.derive("pw", salt), crypto.derive("pw", salt))
        self.assertNotEqual(crypto.derive("pw", salt), crypto.derive("pw2", salt))

    def test_b64_roundtrip(self) -> None:
        raw = crypto.new_key()
        self.assertEqual(crypto.b64d(crypto.b64e(raw)), raw)


class VaultTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.vault = Vault(self.base / "vault")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_create_unlock_and_wrong_password(self) -> None:
        self.vault.create("password123")
        self.assertTrue(self.vault.exists())
        self.assertTrue((self.base / "vault" / "vault.json").exists())
        self.vault.lock()
        self.assertFalse(self.vault.unlocked)
        self.vault.unlock("password123")
        self.assertTrue(self.vault.unlocked)
        self.vault.lock()
        with self.assertRaises(VaultError):
            self.vault.unlock("wrong-password")

    def test_meta_has_no_plaintext_key(self) -> None:
        self.vault.create("password123")
        meta = json.loads((self.base / "vault" / "vault.json").read_text(encoding="utf-8"))
        self.assertNotIn("key", meta)
        self.assertIn("wrapped_key", meta)
        self.assertNotIn("password123", json.dumps(meta))

    def test_change_password(self) -> None:
        self.vault.create("password123")
        first_key = self.vault.key
        self.vault.change_password("password123", "newpassword")
        self.assertEqual(self.vault.key, first_key)
        self.vault.lock()
        with self.assertRaises(VaultError):
            self.vault.unlock("password123")
        self.vault.unlock("newpassword")
        self.assertEqual(self.vault.key, first_key)

    def test_reset_clears_vault_and_allows_recreate(self) -> None:
        self.vault.create("password123")
        store = VaultStore(self.vault)
        store.create("保留下来的便签", "内容")
        doomed = store.create("回收站目标", "待删")
        store.delete(doomed.id)
        self.assertTrue(any(self.vault.trash_dir.glob("*.mdenc")))

        self.vault.reset()

        self.assertFalse(self.vault.exists())
        self.assertFalse(self.vault.unlocked)
        self.assertEqual(list(self.vault.root.iterdir()), [])
        # 重置后可以重新创建，旧密码不再有效
        self.vault.create("newpassword")
        fresh = VaultStore(self.vault)
        self.assertEqual(fresh.all_notes(), [])
        self.assertEqual(fresh.list_trash(), [])

    def test_store_crud_and_ciphertext(self) -> None:
        self.vault.create("password123")
        store = VaultStore(self.vault)
        note = store.create("私密标题", "# 私密\n\n内容")
        path = self.base / "vault" / "items" / f"{note.id}.mdenc"
        self.assertTrue(path.exists())
        raw = path.read_bytes()
        self.assertNotIn("私密标题".encode("utf-8"), raw)
        self.assertNotIn("内容".encode("utf-8"), raw)

        note.content = "更新后"
        store.save(note)

        # 新 Vault 未解锁时不能构造 VaultStore
        locked = Vault(self.base / "vault")
        with self.assertRaises(VaultError):
            VaultStore(locked)

        freshly = Vault(self.base / "vault")
        freshly.unlock("password123")
        store2 = VaultStore(freshly)
        self.assertEqual(store2.get(note.id).content, "更新后")
        self.assertEqual(store2.get(note.id).title, "私密标题")

    def test_delete_moves_to_encrypted_trash(self) -> None:
        self.vault.create("password123")
        store = VaultStore(self.vault)
        note = store.create("待删", "x")
        self.assertTrue(store.delete(note.id))
        self.assertFalse((self.base / "vault" / "items" / f"{note.id}.mdenc").exists())
        self.assertEqual(len(list((self.base / "vault" / "trash").glob("*.mdenc"))), 1)

    def test_trash_list_and_restore(self) -> None:
        self.vault.create("password123")
        store = VaultStore(self.vault)
        note = store.create("私密待删", "# 私密待删\n\n内容")
        store.delete(note.id)
        entries = store.list_trash()
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0].title, "私密待删")
        self.assertEqual(entries[0].source, "vault")
        restored = store.restore_trash(entries[0])
        self.assertIsNotNone(restored)
        self.assertEqual(restored.title, "私密待删")
        self.assertIn("内容", store.get(restored.id).content)
        self.assertEqual(store.list_trash(), [])

    def test_migrate_trash_removes_plaintext(self) -> None:
        self.vault.create("password123")
        trash = self.base / "trash"
        trash.mkdir(parents=True, exist_ok=True)
        (trash / "old.md").write_text("明文旧笔记", encoding="utf-8")
        count = self.vault.migrate_trash(trash)
        self.assertEqual(count, 1)
        self.assertFalse((trash / "old.md").exists())
        blobs = list((self.base / "vault" / "trash").glob("*.mdenc"))
        self.assertEqual(len(blobs), 1)
        self.assertNotIn("明文旧笔记".encode("utf-8"), blobs[0].read_bytes())


class VaultBackupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self._saved = {name: getattr(cfgmod, name) for name in PATH_NAMES}
        _patch_paths(self.base)

        plain = Store()
        plain.create("普通便签", "明文内容")

        vault = Vault()
        vault.create("password123")
        store = VaultStore(vault)
        store.create("私密便签", "密文内容")
        vault.lock()

        meta = json.loads(cfgmod.VAULT_META_PATH.read_text(encoding="utf-8"))
        meta["dpapi_key"] = "ZmFrZS1kcGFwaS1rZXk="
        cfgmod.VAULT_META_PATH.write_text(
            json.dumps(meta, ensure_ascii=False), encoding="utf-8"
        )

        self.cfg = cfgmod.Config(cfgmod.CONFIG_PATH)
        self.cfg.set("onedrive.enabled", True)
        self.cfg.set("onedrive.folder", str(self.base / "OneDrive"))
        self.cfg.set("onedrive.subfolder", "备份")
        self.cfg.set("onedrive.mirror_notes", True)
        (self.base / "OneDrive").mkdir()

    def tearDown(self) -> None:
        for name, value in self._saved.items():
            setattr(cfgmod, name, value)
        self.tmp.cleanup()

    def test_zip_contains_plaintext_and_ciphertext(self) -> None:
        path = backup.create_backup_zip(vault=True)
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            self.assertTrue(any(name.startswith("notes/") for name in names))
            self.assertTrue(any(name.startswith("vault/items/") for name in names))
            self.assertIn("vault/vault.json", names)
            meta = json.loads(archive.read("vault/vault.json").decode("utf-8"))
        self.assertNotIn("dpapi_key", meta)
        self.assertIn("wrapped_key", meta)

    def test_folder_sync_mirrors_both_libraries(self) -> None:
        zip_path = backup.create_backup_zip(vault=True)
        detail = backup.sync_onedrive(self.cfg, zip_path)
        target = self.base / "OneDrive" / "备份"
        self.assertIn("已同步", detail)
        self.assertTrue((target / "notes").is_dir())
        self.assertEqual(len(list((target / "notes").glob("*.md"))), 1)
        self.assertEqual(len(list((target / "vault" / "items").glob("*.mdenc"))), 1)
        meta = json.loads((target / "vault" / "vault.json").read_text(encoding="utf-8"))
        self.assertNotIn("dpapi_key", meta)

    def test_github_staging_contains_both(self) -> None:
        staging = backup._stage_github_source()
        self.assertEqual(len(list(staging.glob("*.md"))), 1)
        self.assertEqual(len(list((staging / "vault" / "items").glob("*.mdenc"))), 1)
        meta = json.loads((staging / "vault" / "vault.json").read_text(encoding="utf-8"))
        self.assertNotIn("dpapi_key", meta)


if __name__ == "__main__":
    unittest.main()
