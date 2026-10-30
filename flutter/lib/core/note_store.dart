/// 明文笔记存储：正文写 Markdown 文件，元数据汇总在 index.json。
///
/// 磁盘格式与 Python 版 `core/storage.py` 完全一致，两个版本可以读写
/// 同一份 `data/`：
/// - `data/notes/<slug>-<id6>.md` 正文
/// - `data/index.json` 元数据（version 1，notes 数组）
/// - `data/trash/<stem>-YYYYMMDD-HHMMSS.md` + 同名 .json 旁注
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'paths.dart';
import 'store_api.dart';

/// 与 Python `_slug()` 同规则：非法字符换空格、空白转连字符、截断 40 字。
String slug(String title, {String fallback = 'note'}) {
  var text = title.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), ' ').trim();
  text = text.replaceAll(RegExp(r'\s+'), '-');
  text = text.replaceAll(RegExp(r'-{2,}'), '-');
  text = text.replaceAll(RegExp(r'^[-._ ]+|[-._ ]+$'), '');
  if (text.length > 40) text = text.substring(0, 40);
  return text.isEmpty ? fallback : text;
}

/// 与 Python `_guess_title()` 一致：第一个标题行，否则第一行前 60 字。
String guessTitle(String content, String fallback) {
  for (final raw in content.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final stripped = line.replaceFirst(RegExp(r'^#+'), '').trim();
      return stripped.isEmpty ? fallback : stripped;
    }
    return line.length > 60 ? line.substring(0, 60) : line;
  }
  return fallback;
}

/// 从回收站文件名里的 `-YYYYMMDD-HHMMSS` 还原删除时间。
DateTime trashStamp(String path) {
  final stem = p.basenameWithoutExtension(path);
  final match = RegExp(r'-(\d{8}-\d{6})$').firstMatch(stem);
  if (match != null) {
    final raw = match.group(1)!;
    final parsed = DateTime.tryParse(
      '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}'
      'T${raw.substring(9, 11)}:${raw.substring(11, 13)}:${raw.substring(13, 15)}',
    );
    if (parsed != null) return parsed;
  }
  try {
    return File(path).statSync().modified;
  } on FileSystemException {
    return DateTime.now();
  }
}

class NoteStore implements NotesStore {
  @override
  final String notesDir;
  final String indexPath;
  @override
  final String trashDir;
  @override
  final Map<String, Note> notes = {};

  NoteStore({
    required this.notesDir,
    required this.indexPath,
    required this.trashDir,
  }) {
    for (final dir in [notesDir, trashDir]) {
      Directory(dir).createSync(recursive: true);
    }
    load();
  }

  factory NoteStore.fromPaths(AppPaths paths) => NoteStore(
        notesDir: paths.notesDir,
        indexPath: paths.indexPath,
        trashDir: paths.trashDir,
      );

  // ---------- 持久化 ----------
  @override
  void load() {
    notes.clear();
    final known = <String>{};

    final indexFile = File(indexPath);
    if (indexFile.existsSync()) {
      Map<String, dynamic> raw = {};
      try {
        final decoded = json.decode(indexFile.readAsStringSync());
        if (decoded is Map<String, dynamic>) raw = decoded;
      } on FormatException {
        raw = {};
      } on FileSystemException {
        raw = {};
      }
      for (final item in (raw['notes'] as List?) ?? const []) {
        if (item is! Map) continue;
        final note = Note.fromDict(Map<String, dynamic>.from(item));
        if (note.filename.isEmpty) {
          note.filename = '${slug(note.title)}-${note.id.substring(0, 6)}.md';
        }
        final file = File(p.join(notesDir, note.filename));
        if (!file.existsSync()) continue;
        try {
          note.content = file.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        notes[note.id] = note;
        known.add(p.basename(file.path));
      }
    }

    // 兼容手工放进 notes 目录的 .md
    final manual = Directory(notesDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.md'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in manual) {
      final name = p.basename(file.path);
      if (known.contains(name)) continue;
      String content;
      try {
        content = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      final note = Note(
        id: newId(),
        title: guessTitle(content, p.basenameWithoutExtension(name)),
        content: content,
        filename: name,
      );
      notes[note.id] = note;
      known.add(name);
    }

    saveIndex();
  }

  @override
  void saveIndex() {
    File(indexPath).parent.createSync(recursive: true);
    final payload = {
      'version': 1,
      'notes': allNotes().map((n) => n.toDict()).toList(),
    };
    final tmp = File('$indexPath.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    tmp.renameSync(indexPath);
  }

  // ---------- CRUD ----------
  @override
  Note create({String title = '', String content = ''}) {
    final note = Note(
      id: newId(),
      title: title.trim().isEmpty ? '未命名笔记' : title.trim(),
      content: content,
    );
    _writeNote(note);
    notes[note.id] = note;
    saveIndex();
    return note;
  }

  @override
  Note save(Note note) {
    note.title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();
    note.updated = isoNow();
    _writeNote(note);
    notes[note.id] = note;
    saveIndex();
    return note;
  }

  @override
  bool delete(String noteId) {
    final note = notes.remove(noteId);
    if (note == null) return false;
    final source = File(p.join(notesDir, note.filename));
    if (source.existsSync()) {
      final stamp = _stampNow();
      final target = p.join(trashDir, '${p.basenameWithoutExtension(source.path)}-$stamp.md');
      try {
        source.renameSync(target);
        // 标题写在 index.json 里，正文不一定有，留一份旁注回收站才显示得对
        final meta = {
          'title': note.title,
          'created': note.created,
          'tags': note.tags,
          'deleted': isoNow(),
        };
        File(target.replaceAll(RegExp(r'\.md$'), '.json'))
            .writeAsStringSync(json.encode(meta), encoding: utf8);
      } on FileSystemException {
        // 移动失败就当没删，与 Python 版一致
      }
    }
    saveIndex();
    return true;
  }

  @override
  Note? get(String noteId) => notes[noteId];

  // ---------- 回收站 ----------
  @override
  List<TrashEntry> listTrash() {
    final entries = <TrashEntry>[];
    final dir = Directory(trashDir);
    if (!dir.existsSync()) return entries;
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.toLowerCase().endsWith('.md')) continue;
      String text;
      try {
        text = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      Map<String, dynamic> meta = {};
      final metaFile = File(file.path.replaceAll(RegExp(r'\.md$'), '.json'));
      if (metaFile.existsSync()) {
        try {
          final decoded = json.decode(metaFile.readAsStringSync());
          if (decoded is Map<String, dynamic>) meta = decoded;
        } on FormatException {
          meta = {};
        } on FileSystemException {
          meta = {};
        }
      }
      final title = (meta['title'] as String?)?.trim().isNotEmpty == true
          ? meta['title'] as String
          : guessTitle(text, p.basenameWithoutExtension(file.path));
      entries.add(TrashEntry(
        path: file.path,
        title: title,
        deletedAt: trashStamp(file.path),
        tags: ((meta['tags'] as List?) ?? const [])
            .map((t) => t.toString())
            .toList(),
      ));
    }
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  @override
  Note? restoreTrash(TrashEntry entry) {
    String content;
    try {
      content = File(entry.path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
    final note = create(title: entry.title, content: content);
    if (entry.tags.isNotEmpty) {
      note.tags = List<String>.from(entry.tags);
      save(note);
    }
    for (final path in [
      entry.path,
      entry.path.replaceAll(RegExp(r'\.md$'), '.json'),
    ]) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // 忽略
      }
    }
    return note;
  }

  // ---------- 查询 ----------
  /// 置顶优先，其余按更新时间倒序。
  @override
  List<Note> allNotes() {
    final list = notes.values.toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updated.compareTo(a.updated);
    });
    return list;
  }

  @override
  List<Note> filter({String query = '', String? tag}) {
    final needle = query.trim().toLowerCase();
    var result = allNotes();
    if (tag != null && tag.isNotEmpty) {
      result = result.where((n) => n.tags.contains(tag)).toList();
    }
    if (needle.isEmpty) return result;
    return result
        .where((n) =>
            '${n.title}\n${n.tags.join(' ')}\n${n.content}'.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Map<String, int> allTags() {
    final counts = <String, int>{};
    for (final note in notes.values) {
      for (final tag in note.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final keys = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    return {for (final k in keys) k: counts[k]!};
  }

  /// 把粘贴进来的图片写到 `notes/assets/`，返回正文里引用的相对路径。
  ///
  /// 用内容 CRC 命名，同一张图重复粘贴不会产生新文件。
  String saveAsset(Uint8List data, String stem) {
    final dir = Directory(p.join(notesDir, 'assets'));
    dir.createSync(recursive: true);
    final crc = _crc32(data).toRadixString(16).padLeft(8, '0');
    final safe = slug(stem, fallback: 'image');
    final name = '$safe-$crc.png';
    final file = File(p.join(dir.path, name));
    if (!file.existsSync()) {
      file.writeAsBytesSync(data);
    }
    return 'assets/$name';
  }

  // ---------- 内部 ----------
  void _writeNote(Note note) {
    final old = notes[note.id];
    var filename = '${slug(note.title)}-${note.id.substring(0, 6)}.md';
    if (old != null && old.filename == filename) {
      filename = old.filename;
    }
    final file = File(p.join(notesDir, filename));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(note.content, encoding: utf8);
    if (old != null && old.filename.isNotEmpty && old.filename != filename) {
      final stale = File(p.join(notesDir, old.filename));
      if (stale.existsSync()) {
        try {
          stale.deleteSync();
        } on FileSystemException {
          // 忽略
        }
      }
    }
    note.filename = filename;
  }
}

String _stampNow([DateTime? at]) {
  final dt = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
      '-${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}

int _crc32(Uint8List data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
