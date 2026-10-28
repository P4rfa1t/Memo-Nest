"""笔记存储：正文保存为 Markdown 文件，元数据汇总在 index.json。"""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from . import config as cfgmod


def iso_now() -> str:
    return datetime.now().replace(microsecond=0).isoformat(sep=" ")


def parse_time(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return datetime.now()


def fmt_time(value: str, short: bool = True) -> str:
    """把 ISO 时间格式化成人类可读的标签。"""
    dt = parse_time(value)
    now = datetime.now()
    if dt.date() == now.date():
        return f"今天 {dt:%H:%M}"
    if dt.year == now.year:
        return f"{dt:%m-%d %H:%M}" if short else f"{dt:%Y-%m-%d %H:%M}"
    return f"{dt:%Y-%m-%d}"


def _slug(title: str, fallback: str = "note") -> str:
    text = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", title).strip()
    text = re.sub(r"\s+", "-", text)
    text = re.sub(r"-{2,}", "-", text).strip("-._ ")
    return text[:40] or fallback


def _guess_title(content: str, fallback: str) -> str:
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("#"):
            return line.lstrip("#").strip() or fallback
        if line:
            return line[:60]
    return fallback


@dataclass
class Note:
    id: str
    title: str = "未命名笔记"
    tags: list[str] = field(default_factory=list)
    created: str = field(default_factory=iso_now)
    updated: str = field(default_factory=iso_now)
    pinned: bool = False
    content: str = ""
    filename: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "title": self.title,
            "tags": self.tags,
            "created": self.created,
            "updated": self.updated,
            "pinned": self.pinned,
            "filename": self.filename,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Note":
        return cls(
            id=str(data.get("id") or uuid.uuid4().hex[:12]),
            title=str(data.get("title") or "未命名笔记"),
            tags=[str(t) for t in data.get("tags") or []],
            created=str(data.get("created") or iso_now()),
            updated=str(data.get("updated") or iso_now()),
            pinned=bool(data.get("pinned")),
            filename=str(data.get("filename") or ""),
        )


class Store:
    """负责笔记的加载、保存、删除与检索。"""

    def __init__(
        self,
        notes_dir: Path | None = None,
        index_path: Path | None = None,
        trash_dir: Path | None = None,
    ) -> None:
        self.notes_dir = Path(notes_dir or cfgmod.NOTES_DIR)
        self.index_path = Path(index_path or cfgmod.INDEX_PATH)
        self.trash_dir = Path(trash_dir or cfgmod.TRASH_DIR)
        self.notes: dict[str, Note] = {}
        for path in (self.notes_dir, self.trash_dir):
            path.mkdir(parents=True, exist_ok=True)
        self.load()

    # ---------- 持久化 ----------
    def load(self) -> None:
        self.notes.clear()
        known: set[str] = set()

        if self.index_path.exists():
            try:
                raw = json.loads(self.index_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                raw = {}
            for item in raw.get("notes", []):
                if not isinstance(item, dict):
                    continue
                note = Note.from_dict(item)
                if not note.filename:
                    note.filename = f"{_slug(note.title)}-{note.id[:6]}.md"
                path = self.notes_dir / note.filename
                if not path.exists():
                    continue
                try:
                    note.content = path.read_text(encoding="utf-8")
                except OSError:
                    continue
                self.notes[note.id] = note
                known.add(path.name)

        # 兼容手工放入 notes 目录的 .md 文件
        for path in sorted(self.notes_dir.glob("*.md")):
            if path.name in known:
                continue
            content = path.read_text(encoding="utf-8", errors="replace")
            note = Note(
                id=uuid.uuid4().hex[:12],
                title=_guess_title(content, path.stem),
                content=content,
                filename=path.name,
            )
            self.notes[note.id] = note
            known.add(path.name)

        self.save_index()

    def save_index(self) -> None:
        self.index_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": 1,
            "notes": [note.to_dict() for note in self.all_notes()],
        }
        tmp = self.index_path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        os.replace(tmp, self.index_path)

    # ---------- CRUD ----------
    def create(self, title: str = "", content: str = "") -> Note:
        note = Note(
            id=uuid.uuid4().hex[:12],
            title=title.strip() or "未命名笔记",
            content=content,
        )
        self._write_note(note)
        self.notes[note.id] = note
        self.save_index()
        return note

    def save(self, note: Note) -> Note:
        note.title = note.title.strip() or "未命名笔记"
        note.updated = iso_now()
        self._write_note(note)
        self.notes[note.id] = note
        self.save_index()
        return note

    def delete(self, note_id: str) -> bool:
        note = self.notes.pop(note_id, None)
        if note is None:
            return False
        source = self.notes_dir / note.filename
        if source.exists():
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            target = self.trash_dir / f"{source.stem}-{stamp}.md"
            try:
                shutil.move(str(source), str(target))
            except OSError:
                pass
        self.save_index()
        return True

    def get(self, note_id: str) -> Note | None:
        return self.notes.get(note_id)

    # ---------- 查询 ----------
    def all_notes(self) -> list[Note]:
        """置顶优先，其余按更新时间倒序。"""
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
        result = []
        for note in notes:
            haystack = f"{note.title}\n{' '.join(note.tags)}\n{note.content}".lower()
            if query in haystack:
                result.append(note)
        return result

    def all_tags(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for note in self.notes.values():
            for tag in note.tags:
                counts[tag] = counts.get(tag, 0) + 1
        return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))

    # ---------- 内部 ----------
    def _write_note(self, note: Note) -> None:
        old = self.notes.get(note.id)
        filename = f"{_slug(note.title)}-{note.id[:6]}.md"
        if old and old.filename == filename:
            filename = old.filename
        (self.notes_dir / filename).write_text(note.content, encoding="utf-8")
        if old and old.filename and old.filename != filename:
            stale = self.notes_dir / old.filename
            if stale.exists():
                try:
                    stale.unlink()
                except OSError:
                    pass
        note.filename = filename
