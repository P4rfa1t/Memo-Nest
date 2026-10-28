"""核心逻辑测试：python -m unittest discover -s tests -v"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from core import backup  # noqa: E402
from core import config as cfgmod  # noqa: E402
from core.markdown import display_width, parse_blocks, parse_inline, strip_markers  # noqa: E402
from core.storage import Store, fmt_time  # noqa: E402


class StorageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.store = Store(
            notes_dir=self.base / "notes",
            index_path=self.base / "index.json",
            trash_dir=self.base / "trash",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_create_and_reload(self) -> None:
        note = self.store.create("第一条", "# 第一条\n\n你好 **世界**")
        self.assertTrue((self.base / "notes" / note.filename).exists())
        self.assertEqual(note.title, "第一条")

        second = Store(
            notes_dir=self.base / "notes",
            index_path=self.base / "index.json",
            trash_dir=self.base / "trash",
        )
        self.assertEqual(len(second.notes), 1)
        loaded = second.get(note.id)
        self.assertIsNotNone(loaded)
        self.assertIn("世界", loaded.content)

    def test_save_updates_time_and_file(self) -> None:
        note = self.store.create("旧标题", "内容")
        old_file = self.base / "notes" / note.filename
        note.title = "新标题"
        note.content = "更新后的内容"
        self.store.save(note)
        self.assertFalse(old_file.exists())
        self.assertTrue((self.base / "notes" / note.filename).exists())
        self.assertEqual(self.store.get(note.id).content, "更新后的内容")
        self.assertGreaterEqual(note.updated, note.created)

    def test_search_and_tags(self) -> None:
        first = self.store.create("购物清单", "- 牛奶\n- 面包")
        first.tags = ["生活"]
        self.store.save(first)
        second = self.store.create("项目计划", "# 计划\n\n- 写代码")
        second.tags = ["工作"]
        self.store.save(second)

        self.assertEqual([n.title for n in self.store.filter("牛奶")], ["购物清单"])
        self.assertEqual([n.title for n in self.store.filter("", "工作")], ["项目计划"])
        self.assertEqual(self.store.all_tags(), {"生活": 1, "工作": 1})
        self.assertEqual(len(self.store.filter("")), 2)

    def test_delete_moves_to_trash(self) -> None:
        note = self.store.create("待删除", "x")
        self.assertTrue(self.store.delete(note.id))
        self.assertEqual(self.store.filter(), [])
        self.assertEqual(len(list((self.base / "trash").glob("*.md"))), 1)

    def test_orphan_markdown_is_imported(self) -> None:
        (self.base / "notes").mkdir(parents=True, exist_ok=True)
        (self.base / "notes" / "手写笔记.md").write_text("# 手写笔记\n\n内容", encoding="utf-8")
        store = Store(
            notes_dir=self.base / "notes",
            index_path=self.base / "index.json",
            trash_dir=self.base / "trash",
        )
        titles = [note.title for note in store.all_notes()]
        self.assertIn("手写笔记", titles)

    def test_pinned_first(self) -> None:
        low = self.store.create("普通", "")
        high = self.store.create("置顶", "")
        high.pinned = True
        self.store.save(high)
        titles = [n.title for n in self.store.all_notes()]
        self.assertEqual(titles[0], "置顶")
        self.assertIn(low.title, titles)

    def test_fmt_time(self) -> None:
        self.assertTrue(fmt_time("2024-01-02 03:04:05").startswith("2024-01-02"))


class MarkdownTests(unittest.TestCase):
    def test_block_types(self) -> None:
        md = """# 标题

段落 **加粗** 内容。

- 项目一
- 项目二

1. 第一
2. 第二

> 引用

```python
print("hi")
```

---

| 名称 | 数量 |
| --- | --- |
| 苹果 | 3 |
"""
        kinds = [block.kind for block in parse_blocks(md)]
        self.assertIn("heading", kinds)
        self.assertIn("paragraph", kinds)
        self.assertIn("list", kinds)
        self.assertIn("quote", kinds)
        self.assertIn("code", kinds)
        self.assertIn("hr", kinds)
        self.assertIn("table", kinds)

    def test_list_and_table_details(self) -> None:
        blocks = parse_blocks("- [x] 完成\n- [ ] 未完成")
        self.assertEqual(blocks[0].kind, "list")
        self.assertEqual(len(blocks[0].items), 2)

        table = parse_blocks("| a | b |\n| --- | --- |\n| 1 | 2 |")[0]
        self.assertEqual(table.header, ["a", "b"])
        self.assertEqual(table.rows, [["1", "2"]])

    def test_inline_styles(self) -> None:
        spans = parse_inline("**粗** *斜* `代码` [链接](https://example.com) ~~删~~")
        text = "".join(span.text for span in spans)
        self.assertIn("粗", text)
        styles = [span.styles for span in spans]
        self.assertTrue(any("bold" in s for s in styles))
        self.assertTrue(any("italic" in s for s in styles))
        self.assertTrue(any("code" in s for s in styles))
        self.assertTrue(any("strike" in s for s in styles))
        link = [span for span in spans if span.url][0]
        self.assertEqual(link.styles and True, True)

    def test_autolink_and_escapes(self) -> None:
        spans = parse_inline("访问 https://example.com 看看")
        links = [span for span in spans if span.url]
        self.assertEqual(len(links), 1)
        self.assertEqual(links[0].url, "https://example.com")
        self.assertEqual(parse_inline(r"\*不是斜体\*")[0].text, "*不是斜体*")

    def test_display_width_and_strip(self) -> None:
        self.assertEqual(display_width("ab"), 2)
        self.assertEqual(display_width("中文"), 4)
        self.assertEqual(strip_markers("**粗** `代` [链接](x)"), "粗 代 链接")


class BackupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.notes = self.base / "notes"
        self.notes.mkdir()
        self.index = self.base / "index.json"
        self.index.write_text(json.dumps({"notes": []}), encoding="utf-8")
        (self.base / "OneDrive").mkdir()
        (self.notes / "a.md").write_text("# A\n\n内容", encoding="utf-8")
        (self.notes / "b.md").write_text("# B", encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _config(self) -> cfgmod.Config:
        cfg = cfgmod.Config(self.base / "config.json")
        cfg.set("onedrive.enabled", True)
        cfg.set("onedrive.folder", str(self.base / "OneDrive"))
        cfg.set("onedrive.subfolder", "备份")
        cfg.set("onedrive.mirror_notes", True)
        cfg.set("onedrive.keep_backups", 2)
        cfg.set("general.keep_backups", 2)
        return cfg

    def test_zip_contents_and_prune(self) -> None:
        backup_dir = self.base / "backups"
        first = backup.create_backup_zip(self.notes, self.index, backup_dir, keep=2)
        with zipfile.ZipFile(first) as archive:
            names = archive.namelist()
        self.assertIn("notes/a.md", names)
        self.assertIn("index.json", names)

        for name in ("20200101-000000", "20200102-000000"):
            (backup_dir / f"memo-backup-{name}.zip").write_bytes(b"x")
        backup.create_backup_zip(self.notes, self.index, backup_dir, keep=2)
        self.assertLessEqual(len(list(backup_dir.glob("*.zip"))), 2)

    def test_onedrive_sync(self) -> None:
        cfg = self._config()
        zip_path = backup.create_backup_zip(self.notes, self.index, self.base / "backups")
        detail = backup.sync_onedrive(cfg, zip_path, self.notes, self.index)
        target = self.base / "OneDrive" / "备份"
        self.assertIn("已同步 2 篇笔记", detail)
        self.assertTrue((target / "notes" / "a.md").exists())
        self.assertTrue((target / zip_path.name).exists())
        self.assertTrue((target / "index.json").exists())

        (self.notes / "b.md").unlink()
        backup.sync_onedrive(cfg, zip_path, self.notes, self.index)
        self.assertFalse((target / "notes" / "b.md").exists())

    def test_onedrive_missing_folder(self) -> None:
        cfg = self._config()
        cfg.set("onedrive.folder", str(self.base / "不存在"))
        with self.assertRaises(backup.BackupError):
            backup.resolve_onedrive_folder(cfg)

    @unittest.skipUnless(subprocess.run(["git", "--version"], capture_output=True).returncode == 0, "需要 git")
    def test_github_push_to_local_bare_repo(self) -> None:
        bare = self.base / "remote.git"
        subprocess.run(
            ["git", "init", "--bare", "-b", "main", str(bare)],
            check=True,
            capture_output=True,
        )
        cfg = self._config()
        cfg.set("github.enabled", True)
        cfg.set("github.branch", "main")
        cfg.set("github.remote_url", bare.as_uri())
        cfg.set("github.author_name", "测试")
        cfg.set("github.author_email", "test@example.com")

        detail = backup.push_to_github(cfg, self.notes)
        self.assertIn("已推送", detail)
        log = subprocess.run(
            ["git", "--git-dir", str(bare), "log", "--oneline"],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        self.assertIn("备忘录自动备份", log.stdout)

        again = backup.push_to_github(cfg, self.notes)
        self.assertIn("无新变更", again)


class ConfigTests(unittest.TestCase):
    def test_defaults_and_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            cfg = cfgmod.Config(path)
            self.assertFalse(cfg.get("onedrive.enabled"))
            self.assertEqual(cfg.get("general.keep_backups"), 20)
            cfg.set("onedrive.enabled", True)
            cfg.set("onedrive.subfolder", "我的备份")
            cfg.save()
            loaded = cfgmod.Config(path)
            self.assertTrue(loaded.get("onedrive.enabled"))
            self.assertEqual(loaded.get("onedrive.subfolder"), "我的备份")
            self.assertTrue(loaded.channels_enabled())

    def test_broken_config_falls_back(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text("{ not json", encoding="utf-8")
            cfg = cfgmod.Config(path)
            self.assertEqual(cfg.get("onedrive.subfolder"), "MemoNest备份")


if __name__ == "__main__":
    unittest.main()
