/// 笔记数据模型：与 Python 版 `core/storage.py` 的 Note / TrashEntry 保持
/// 同一套字段名，这样 index.json 与 .mdenc 里的 JSON 两边都能读。
library;

/// 与 Python `iso_now()` 一致：本地时间、秒级精度、空格分隔。
String isoNow([DateTime? at]) {
  final dt = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}'
      ' ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

DateTime parseTime(String? value) {
  if (value == null || value.isEmpty) return DateTime.now();
  return DateTime.tryParse(value.replaceFirst(' ', 'T')) ?? DateTime.now();
}

/// 人类可读的时间标签，规则与 Python `fmt_time()` 相同。
String fmtTime(String value, {bool short = true}) {
  final dt = parseTime(value);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (sameDay) return '今天 ${two(dt.hour)}:${two(dt.minute)}';
  if (dt.year == now.year) {
    return short
        ? '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}'
        : '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
  return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
}

class Note {
  String id;
  String title;
  List<String> tags;
  String created;
  String updated;
  bool pinned;
  String content;
  String filename;

  Note({
    required this.id,
    this.title = '未命名笔记',
    List<String>? tags,
    String? created,
    String? updated,
    this.pinned = false,
    this.content = '',
    this.filename = '',
  })  : tags = tags ?? <String>[],
        created = created ?? isoNow(),
        updated = updated ?? isoNow();

  factory Note.fromDict(Map<String, dynamic> data) {
    return Note(
      id: (data['id'] as String?)?.trim().isNotEmpty == true
          ? data['id'] as String
          : newId(),
      title: (data['title'] as String?) ?? '未命名笔记',
      tags: ((data['tags'] as List?) ?? const [])
          .map((t) => t.toString())
          .toList(growable: true),
      created: (data['created'] as String?) ?? isoNow(),
      updated: (data['updated'] as String?) ?? isoNow(),
      pinned: data['pinned'] == true,
      filename: (data['filename'] as String?) ?? '',
    );
  }

  /// 注意：与 Python 版一样，这里**不含** content —— 正文单独存文件。
  Map<String, dynamic> toDict() => {
        'id': id,
        'title': title,
        'tags': tags,
        'created': created,
        'updated': updated,
        'pinned': pinned,
        'filename': filename,
      };

  Note copy() => Note(
        id: id,
        title: title,
        tags: List<String>.from(tags),
        created: created,
        updated: updated,
        pinned: pinned,
        content: content,
        filename: filename,
      );
}

class TrashEntry {
  final String path;
  final String title;
  final DateTime deletedAt;
  final String source; // note | vault
  final String noteId;
  final List<String> tags;

  TrashEntry({
    required this.path,
    required this.title,
    required this.deletedAt,
    this.source = 'note',
    this.noteId = '',
    List<String>? tags,
  }) : tags = tags ?? <String>[];

  String get deletedLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${deletedAt.year}-${two(deletedAt.month)}-${two(deletedAt.day)}'
        ' ${two(deletedAt.hour)}:${two(deletedAt.minute)}';
  }

  String get sourceLabel => source == 'vault' ? '私密便签' : '普通便签';
}

const _idAlphabet = '0123456789abcdef';

/// 12 位十六进制 id，和 Python `uuid.uuid4().hex[:12]` 的形态一致。
String newId() {
  final rand = _RandomSource();
  final buf = StringBuffer();
  for (var i = 0; i < 12; i++) {
    buf.write(_idAlphabet[rand.next(16)]);
  }
  return buf.toString();
}

class _RandomSource {
  final DateTime _seedBase = DateTime.now();
  int _counter = 0;
  int _state = 0;

  _RandomSource() {
    _state = _seedBase.microsecondsSinceEpoch & 0x7fffffff;
    if (_state == 0) _state = 1;
  }

  /// xorshift32：够用且不引入依赖；id 不需要密码学强度。
  int next(int max) {
    _counter++;
    var x = _state;
    x ^= (x << 13) & 0xffffffff;
    x ^= x >> 17;
    x ^= (x << 5) & 0xffffffff;
    _state = x & 0xffffffff;
    final mixed = (x + _counter * 2654435761) & 0x7fffffff;
    return mixed % max;
  }
}
