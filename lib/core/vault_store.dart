/// 加密笔记库：主密码 + AES-256-GCM 逐条加密。
///
/// 磁盘格式与 Python 版 `core/vault.py` **完全一致**：
/// - `data/vault/vault.json`：kdf 参数、被 KEK 包裹的库密钥、密钥指纹
/// - `data/vault/items/<id>.mdenc`：每条笔记独立加密，文件名不含标题
/// - `data/vault/trash/<id>-<stamp>.mdenc`：回收站
///
/// 这意味着 Flutter 版可以直接打开 Python 版创建的私密库，反之亦然。
/// 迁移时务必保持：AAD 字符串、密文布局、scrypt 参数三者不变。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'crypto.dart' as crypto;
import 'models.dart';
import 'store_api.dart';

class VaultError implements Exception {
  final String message;
  VaultError(this.message);
  @override
  String toString() => message;
}

class Vault {
  final String root;
  Uint8List? _key;

  Vault(this.root);

  String get metaPath => p.join(root, 'vault.json');
  String get itemsDir => p.join(root, 'items');
  String get trashDir => p.join(root, 'trash');

  bool get unlocked => _key != null;
  Uint8List? get key => _key;

  bool exists() => File(metaPath).existsSync();

  Map<String, dynamic> meta() {
    final file = File(metaPath);
    if (!file.existsSync()) return {};
    try {
      final decoded = json.decode(file.readAsStringSync());
      return decoded is Map<String, dynamic> ? decoded : {};
    } on FormatException {
      return {};
    } on FileSystemException {
      return {};
    }
  }

  void _saveMeta(Map<String, dynamic> meta) {
    Directory(root).createSync(recursive: true);
    final tmp = File('$metaPath.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(meta),
      encoding: utf8,
    );
    tmp.renameSync(metaPath);
  }

  // ---------- 创建 / 解锁 ----------
  void create(String password) {
    if (exists()) throw VaultError('加密库已存在');
    if (password.length < 6) throw VaultError('主密码至少 6 位，建议 10 位以上');
    final salt = crypto.newSalt();
    final kek = crypto.derive(password, salt);
    final key = crypto.newKey();
    final meta = <String, dynamic>{
      'version': 1,
      'kdf': {
        'name': 'scrypt',
        'salt': crypto.b64e(salt),
        'n': crypto.scryptN,
        'r': crypto.scryptR,
        'p': crypto.scryptP,
      },
      'wrapped_key': crypto.b64e(crypto.encrypt(kek, key, crypto.aadMeta)),
      'key_tag': crypto.keyTag(key),
      'created': isoNow(),
    };
    Directory(root).createSync(recursive: true);
    Directory(itemsDir).createSync(recursive: true);
    Directory(trashDir).createSync(recursive: true);
    _saveMeta(meta);
    _key = key;
  }

  Uint8List _kek(String password, Map<String, dynamic> meta) {
    final kdf = meta['kdf'];
    if (kdf is! Map) throw VaultError('vault.json 已损坏');
    final saltText = kdf['salt'];
    if (saltText is! String || saltText.isEmpty) {
      throw VaultError('vault.json 已损坏');
    }
    Uint8List salt;
    try {
      salt = crypto.b64d(saltText);
    } on FormatException {
      throw VaultError('vault.json 已损坏');
    }
    return crypto.derive(
      password,
      salt,
      n: (kdf['n'] as num?)?.toInt() ?? crypto.scryptN,
      r: (kdf['r'] as num?)?.toInt() ?? crypto.scryptR,
      p: (kdf['p'] as num?)?.toInt() ?? crypto.scryptP,
    );
  }

  void unlock(String password) {
    final m = meta();
    if (m.isEmpty) throw VaultError('找不到加密库');
    final kek = _kek(password, m);
    final wrapped = m['wrapped_key'];
    if (wrapped is! String) throw VaultError('vault.json 已损坏');
    Uint8List key;
    try {
      key = crypto.decrypt(kek, crypto.b64d(wrapped), crypto.aadMeta);
    } on FormatException {
      throw VaultError('vault.json 已损坏');
    } on crypto.CryptoError {
      throw VaultError('主密码不正确');
    }
    final tag = m['key_tag'];
    if (tag is String && tag.isNotEmpty && crypto.keyTag(key) != tag) {
      throw VaultError('密钥校验失败，vault.json 可能被替换');
    }
    _key = key;
  }

  void lock() {
    _key = null;
  }

  /// 用已经解出来的密钥直接打开（Windows Hello 解锁走这条路）。
  ///
  /// 会用 `key_tag` 核对密钥确实属于这个库，对不上就抛 [VaultError]，
  /// 免得把错误的密钥写进去、之后每次读写笔记都报解密失败。
  void unlockWithKey(Uint8List key) {
    if (key.length != crypto.keyBytes) {
      throw VaultError('库密钥长度不正确');
    }
    final m = meta();
    if (m.isEmpty) throw VaultError('找不到加密库');
    final tag = m['key_tag'];
    if (tag is String && tag.isNotEmpty && crypto.keyTag(key) != tag) {
      throw VaultError('Hello 凭据与当前私密库不匹配，请用主密码解锁');
    }
    _key = Uint8List.fromList(key);
  }

  /// 忘记主密码时彻底清空加密库（不可恢复）。
  void reset() {
    _key = null;
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略
    }
  }

  // ---------- 修改主密码 ----------
  void changePassword(String oldPassword, String newPassword) {
    unlock(oldPassword);
    if (newPassword.length < 6) throw VaultError('新密码至少 6 位');
    final key = _key!;
    final m = meta();
    final salt = crypto.newSalt();
    final kek = crypto.derive(newPassword, salt);
    m['kdf'] = {
      'name': 'scrypt',
      'salt': crypto.b64e(salt),
      'n': crypto.scryptN,
      'r': crypto.scryptR,
      'p': crypto.scryptP,
    };
    m['wrapped_key'] = crypto.b64e(crypto.encrypt(kek, key, crypto.aadMeta));
    _saveMeta(m);
  }

  // ---------- 序列化 ----------
  Uint8List sealNote(Note note) {
    final key = _key;
    if (key == null) throw VaultError('加密库已锁定');
    final payload = note.toDict();
    payload['content'] = note.content;
    final data = Uint8List.fromList(utf8.encode(json.encode(payload)));
    return crypto.encrypt(key, data, crypto.noteAad(note.id));
  }

  Map<String, dynamic> openNote(Uint8List blob, String noteId) {
    final key = _key;
    if (key == null) throw VaultError('加密库已锁定');
    final data = crypto.decrypt(key, blob, crypto.noteAad(noteId));
    final decoded = json.decode(utf8.decode(data));
    return decoded is Map<String, dynamic> ? decoded : {};
  }
}

class VaultStore implements NotesStore {
  final Vault vault;
  @override
  final Map<String, Note> notes = {};

  VaultStore(this.vault) {
    if (vault.key == null) throw VaultError('加密库尚未解锁');
    Directory(vault.itemsDir).createSync(recursive: true);
    Directory(vault.trashDir).createSync(recursive: true);
    load();
  }

  @override
  String get notesDir => vault.itemsDir;
  @override
  String get trashDir => vault.trashDir;

  @override
  void load() {
    notes.clear();
    final dir = Directory(notesDir);
    if (!dir.existsSync()) return;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.mdenc'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final noteId = p.basenameWithoutExtension(file.path);
      Map<String, dynamic> payload;
      try {
        payload = vault.openNote(file.readAsBytesSync(), noteId);
      } on Exception {
        continue; // 解不开就跳过，别让一条坏文件挡住整个库
      }
      final note = Note.fromDict(payload);
      note.id = noteId;
      note.content = (payload['content'] as String?) ?? '';
      note.filename = p.basename(file.path);
      notes[note.id] = note;
    }
  }

  // 加密库不落盘明文索引
  @override
  void saveIndex() {}

  @override
  Note create({String title = '', String content = ''}) {
    final note = Note(
      id: newId(),
      title: title.trim().isEmpty ? '未命名笔记' : title.trim(),
      content: content,
    );
    save(note);
    return note;
  }

  @override
  Note save(Note note) {
    final key = vault.key;
    if (key == null) throw VaultError('加密库已锁定');
    note.title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();
    note.updated = isoNow();
    note.filename = '${note.id}.mdenc';
    final tmp = File(p.join(notesDir, '.${note.id}.tmp'));
    tmp.parent.createSync(recursive: true);
    tmp.writeAsBytesSync(vault.sealNote(note));
    tmp.renameSync(p.join(notesDir, note.filename));
    notes[note.id] = note;
    return note;
  }

  @override
  bool delete(String noteId) {
    final note = notes.remove(noteId);
    if (note == null) return false;
    final source = File(p.join(notesDir, note.filename));
    if (source.existsSync()) {
      final stamp = _stampNow();
      try {
        source.renameSync(p.join(trashDir, '$noteId-$stamp.mdenc'));
      } on FileSystemException {
        // 忽略
      }
    }
    return true;
  }

  @override
  Note? get(String noteId) => notes[noteId];

  // ---------- 回收站 ----------
  (Map<String, dynamic>?, String) _readTrash(String path) {
    final key = vault.key;
    if (key == null) return (null, '');
    final stem = p.basenameWithoutExtension(path);
    final noteId = stem.split('-').first;
    if (noteId.isNotEmpty) {
      try {
        return (vault.openNote(File(path).readAsBytesSync(), noteId), '');
      } on Exception {
        // 落到下面的明文分支
      }
    }
    try {
      final text = crypto.decrypt(
        key,
        File(path).readAsBytesSync(),
        crypto.aadTrash,
      );
      return (null, utf8.decode(text, allowMalformed: true));
    } on Exception {
      return (null, '');
    }
  }

  @override
  List<TrashEntry> listTrash() {
    final entries = <TrashEntry>[];
    final dir = Directory(trashDir);
    if (!dir.existsSync()) return entries;
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.toLowerCase().endsWith('.mdenc')) continue;
      final (payload, text) = _readTrash(file.path);
      if (payload == null && text.isEmpty) continue;
      String title;
      String noteId;
      List<String> tags;
      if (payload != null) {
        title = (payload['title'] as String?) ?? '未命名笔记';
        noteId = p.basenameWithoutExtension(file.path).split('-').first;
        tags = ((payload['tags'] as List?) ?? const [])
            .map((t) => t.toString())
            .toList();
      } else {
        title = guessTitleLocal(text, p.basenameWithoutExtension(file.path));
        noteId = '';
        tags = [];
      }
      entries.add(TrashEntry(
        path: file.path,
        title: title,
        deletedAt: _stampParse(file.path),
        source: 'vault',
        noteId: noteId,
        tags: tags,
      ));
    }
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  @override
  Note? restoreTrash(TrashEntry entry) {
    final (payload, text) = _readTrash(entry.path);
    if (payload == null && text.isEmpty) return null;
    Note note;
    if (payload != null) {
      note = Note.fromDict(payload);
      note.id = newId();
      note.content = (payload['content'] as String?) ?? '';
    } else {
      note = Note(
        id: newId(),
        title: guessTitleLocal(text, '未命名笔记'),
        content: text,
      );
    }
    note.updated = isoNow();
    save(note);
    try {
      File(entry.path).deleteSync();
    } on FileSystemException {
      // 忽略
    }
    return note;
  }

  // ---------- 查询 ----------
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
        .where((n) => '${n.title}\n${n.tags.join(' ')}\n${n.content}'
            .toLowerCase()
            .contains(needle))
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
}

String guessTitleLocal(String content, String fallback) {
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

DateTime _stampParse(String path) {
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

String _stampNow([DateTime? at]) {
  final dt = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
      '-${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}
