/// GitHub 双向同步的合并引擎。
///
/// 之前只有「备份」：本地 `index.json` + `notes/*.md` 直接盖掉云端，
/// 手机上删掉的文件、另一台机器上新写的便签，全都在这台机器的推送里
/// 被抹掉。这里改成真正的同步——先取回云端，跟本地做三方合并，
/// 再把合并结果推上去。
///
/// ## 为什么需要一份本地清单（manifest）
///
/// 只有「本地 vs 云端」两份状态时，没法区分两种完全相反的情况：
/// - 云端没有这篇 → 也许是本地新写的（该上传），也许是云端删掉的（该本地删）
/// - 本地没有这篇 → 也许是云端新加的（该下载），也许是本地删掉的（该云端删）
///
/// 所以把「上一次同步完成时两边一致的快照」存在
/// `data/github-sync.json`：拿 `manifest` 当基准点，就能判出**哪一边动过**。
/// 首次同步没有基准点，按「取并集、时间新的赢、输的一方留成冲突副本」处理，
/// 保证任何情况下不丢数据。
///
/// ## 冲突策略
///
/// 两边都改过同一篇、且内容确实不同 → 时间新的留在原文件，旧的那份另存成
/// `<标题>（本机副本 / 云端副本）` 的新便签。宁可多出一篇，也不静默丢字。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'note_store.dart' show guessTitle, slug;
import 'paths.dart';

/// 一次同步的计数。`describe()` 把它拼成一句给用户看的话。
class SyncCounts {
  int pulled = 0; // 云端较新，覆盖本地
  int pushed = 0; // 本地较新，传到云端
  int addedLocal = 0; // 云端新增，落到本地
  int addedRemote = 0; // 本地新增，推到云端
  int removedLocal = 0; // 云端删了，本地也删
  int removedRemote = 0; // 本地删了，云端也删
  int conflicts = 0; // 两边都改，留了副本

  /// 这次同步有没有改动本地磁盘——有的话界面要重新加载笔记列表。
  bool get touchedLocal => pulled + addedLocal + removedLocal + conflicts > 0;

  bool get touchedRemote =>
      pushed + addedRemote + removedRemote + conflicts > 0;

  bool get empty => !touchedLocal && !touchedRemote;

  String describe(String repo, String branch) {
    if (empty) return '已是最新（$repo $branch 分支）';
    final parts = <String>[];
    if (addedLocal > 0) parts.add('取回新增 $addedLocal');
    if (pulled > 0) parts.add('更新本地 $pulled');
    if (removedLocal > 0) parts.add('本地删除 $removedLocal');
    if (addedRemote > 0) parts.add('上传新增 $addedRemote');
    if (pushed > 0) parts.add('上传更新 $pushed');
    if (removedRemote > 0) parts.add('云端删除 $removedRemote');
    if (conflicts > 0) parts.add('冲突副本 $conflicts');
    return '已同步 $repo（$branch 分支）：${parts.join('，')}';
  }
}

/// 合并结果：要写到磁盘上的笔记、要提交到仓库的文件、要删掉的仓库路径。
class SyncPlan {
  /// 合并后的笔记记录（写回 `index.json`）。
  final List<Map<String, dynamic>> notes;

  /// id → 正文（UTF-8 字节）。键一定出现在 [notes] 里。
  final Map<String, List<int>> contents;

  final SyncCounts counts;

  /// 仓库路径 → 内容。`notes/*.md`、`index.json`、`vault/*`。
  final Map<String, List<int>> files;

  /// 云端该删掉的路径。
  final Set<String> removals;

  /// 本地磁盘是否需要重写。
  final bool localDirty;

  SyncPlan({
    required this.notes,
    required this.contents,
    required this.counts,
    required this.files,
    required this.removals,
    required this.localDirty,
  });
}

/// 参与同步的仓库路径前缀。
const String notesPrefix = 'notes/';
const String indexFileName = 'index.json';
const String vaultPrefix = 'vault/';

/// 合并引擎。[merge] 纯计算，[applyLocal] 负责落盘。
class GitHubSync {
  final AppPaths paths;

  GitHubSync(this.paths);

  /// 上次同步完成的基准点文件。
  String get manifestPath => p.join(paths.dataDir, 'github-sync.json');

  // ---------------- 读本地 ----------------

  /// 本地 `index.json` 的记录。文件缺失或损坏时退化成扫描 `notes/` 目录，
  /// 与 [NoteStore.load] 的兜底行为一致，免得手工放进来的 md 全被当成删除。
  List<Map<String, dynamic>> readLocalIndex() {
    final file = File(paths.indexPath);
    if (file.existsSync()) {
      try {
        final decoded = json.decode(file.readAsStringSync());
        if (decoded is Map && decoded['notes'] is List) {
          final list = <Map<String, dynamic>>[];
          for (final item in decoded['notes'] as List) {
            if (item is! Map) continue;
            final dict = Map<String, dynamic>.from(item);
            final id = '${dict['id'] ?? ''}'.trim();
            if (id.isEmpty) continue;
            if ('${dict['filename'] ?? ''}'.trim().isEmpty) {
              dict['filename'] = '${slug('${dict['title'] ?? ''}')}-'
                  '${id.substring(0, id.length >= 6 ? 6 : id.length)}.md';
            }
            list.add(dict);
          }
          return list;
        }
      } on FormatException {
        // 落到下面扫目录
      } on FileSystemException {
        // 落到下面扫目录
      }
    }

    final list = <Map<String, dynamic>>[];
    final dir = Directory(paths.notesDir);
    if (!dir.existsSync()) return list;
    for (final file in dir.listSync().whereType<File>()) {
      if (!file.path.toLowerCase().endsWith('.md')) continue;
      final name = p.basename(file.path);
      String content;
      try {
        content = file.readAsStringSync();
      } on FileSystemException {
        continue;
      }
      list.add(Note(
        id: _fileId(name),
        title: guessTitle(content, p.basenameWithoutExtension(name)),
        filename: name,
      ).toDict());
    }
    return list;
  }

  /// 从文件名推一个稳定 id。
  ///
  /// 走了兜底扫描（`index.json` 缺失或损坏）时不能再用 `newId()`：同一篇
  /// 笔记每次读到的 id 都不一样，`manifest` 永远对不上基准点，于是每次
  /// 同步都判定成「新增」重复上传，冲突判定也全部失效。用文件名哈希，
  /// 同一个文件名永远得到同一个 id。
  String _fileId(String name) {
    // FNV-1a：一行能写完，够短够散，不用为此引一个依赖。
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(name)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return 'md-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  /// 本地正文：id → 字节。文件不在的键不会出现（等同「本地没有这篇」）。
  Map<String, List<int>> readLocalContents(List<Map<String, dynamic>> notes) {
    final result = <String, List<int>>{};
    for (final dict in notes) {
      final id = '${dict['id'] ?? ''}';
      final name = '${dict['filename'] ?? ''}';
      if (id.isEmpty || name.isEmpty) continue;
      final file = File(p.join(paths.notesDir, name));
      if (!file.existsSync()) continue;
      try {
        result[id] = file.readAsBytesSync();
      } on FileSystemException {
        // 读不到就当不存在，下次再来
      }
    }
    return result;
  }

  /// 本地有没有私密库。没有的话**绝不能**去删云端的 vault/——
  /// 换台机器登录一下就把别人的密文抹了，那是灾难。
  bool get hasLocalVault =>
      File(paths.vaultMetaPath).existsSync() ||
      Directory(paths.vaultItemsDir).existsSync();

  /// 要上传的文件全集，布局与 HTTP 版一致：
  /// `notes/<name>.md` + `index.json` + `vault/items/<name>.mdenc` + `vault/vault.json`。
  Map<String, List<int>> collectRepoFiles(
      List<Map<String, dynamic>> notes, Map<String, List<int>> contents) {
    final files = <String, List<int>>{};

    final ordered = List<Map<String, dynamic>>.from(notes)
      ..sort((a, b) =>
          '${a['filename'] ?? ''}'.compareTo('${b['filename'] ?? ''}'));
    for (final dict in ordered) {
      final id = '${dict['id'] ?? ''}';
      final name = '${dict['filename'] ?? ''}';
      final bytes = contents[id];
      if (name.isEmpty || bytes == null) continue;
      files['$notesPrefix$name'] = bytes;
    }

    files[indexFileName] = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': 1,
        'notes': ordered,
      }),
    );

    if (hasLocalVault) {
      final items = Directory(paths.vaultItemsDir);
      if (items.existsSync()) {
        final names = items
            .listSync()
            .whereType<File>()
            .map((f) => p.basename(f.path))
            .where((n) => n.toLowerCase().endsWith('.mdenc'))
            .toList()
          ..sort();
        for (final name in names) {
          try {
            files['${vaultPrefix}items/$name'] =
                File(p.join(items.path, name)).readAsBytesSync();
          } on FileSystemException {
            // 单个文件读失败不该挡住整次同步
          }
        }
      }
      final meta = File(paths.vaultMetaPath);
      if (meta.existsSync()) {
        Map<String, dynamic> payload = {};
        try {
          final decoded = json.decode(meta.readAsStringSync());
          if (decoded is Map<String, dynamic>) payload = decoded;
        } on FormatException {
          payload = {};
        } on FileSystemException {
          payload = {};
        }
        // 这台机器的密钥材料绝不进云端：换台机器解不开，泄露也没意义。
        payload.remove('dpapi_key');
        files['${vaultPrefix}vault.json'] =
            utf8.encode(const JsonEncoder.withIndent('  ').convert(payload));
      }
    }
    return files;
  }

  // ---------------- 基准点 ----------------

  /// `{ "version": 1, "notes": { "<id>": {"updated": "...", "filename": "..."} } }`
  Map<String, Map<String, dynamic>> readManifest() {
    final file = File(manifestPath);
    if (!file.existsSync()) return {};
    try {
      final decoded = json.decode(file.readAsStringSync());
      if (decoded is Map && decoded['notes'] is Map) {
        final result = <String, Map<String, dynamic>>{};
        (decoded['notes'] as Map).forEach((key, value) {
          if (value is Map) {
            result['$key'] = Map<String, dynamic>.from(value);
          }
        });
        return result;
      }
    } on FormatException {
      // 损坏就当首次同步
    } on FileSystemException {
      // 同上
    }
    return {};
  }

  void _saveManifest(List<Map<String, dynamic>> notes) {
    final payload = <String, dynamic>{
      'version': 1,
      'synced_at': isoNow(),
      'notes': <String, dynamic>{
        for (final dict in notes)
          '${dict['id'] ?? ''}': <String, dynamic>{
            'updated': '${dict['updated'] ?? ''}',
            'filename': '${dict['filename'] ?? ''}',
            'title': '${dict['title'] ?? ''}',
          },
      },
    };
    try {
      Directory(p.dirname(manifestPath)).createSync(recursive: true);
      final tmp = File('$manifestPath.tmp');
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload),
          encoding: utf8);
      tmp.renameSync(manifestPath);
    } on FileSystemException {
      // 写不了基准点只会让下次退化成首次同步，不该让整次同步失败
    }
  }

  // ---------------- 合并 ----------------

  /// 三方合并。[remote] 是云端仓库的 `路径 → 字节`，必须含 `index.json`。
  ///
  /// 只读本地、不写盘；写盘交给 [applyLocal]，方便「先合并再决定提交方式」
  /// （git 引擎要自己 commit）。
  SyncPlan merge(Map<String, List<int>> remote) {
    final counts = SyncCounts();
    final manifest = readManifest();
    final localNotes = readLocalIndex();
    final localContent = readLocalContents(localNotes);

    final remoteNotes = _parseRemoteIndex(remote);
    final remoteContent = <String, List<int>>{};
    for (final dict in remoteNotes) {
      final name = '${dict['filename'] ?? ''}';
      final bytes = remote['$notesPrefix$name'];
      if (bytes != null) remoteContent['${dict['id'] ?? ''}'] = bytes;
    }

    final localById = <String, Map<String, dynamic>>{
      for (final dict in localNotes) '${dict['id'] ?? ''}': dict,
    };
    final remoteById = <String, Map<String, dynamic>>{
      for (final dict in remoteNotes) '${dict['id'] ?? ''}': dict,
    };

    final merged = <Map<String, dynamic>>[];
    final contents = <String, List<int>>{};
    final usedNames = <String>{};
    final ids = <String>{
      ...localById.keys,
      ...remoteById.keys,
    };

    for (final id in ids) {
      final local = localById[id];
      final remoteNote = remoteById[id];
      final base = manifest[id];

      if (local == null && remoteNote == null) continue;

      if (local != null && remoteNote == null) {
        // 只有本地有：新增，或者云端删了
        if (base == null) {
          _adopt(merged, contents, usedNames, local,
              localContent[id] ?? const <int>[]);
          counts.addedRemote++;
        } else if ('${local['updated'] ?? ''}' == '${base['updated'] ?? ''}') {
          // 本地从上次同步后没动 → 云端那次删除是有意的，跟着删
          counts.removedLocal++;
        } else {
          // 云端删了，但本地又改过 → 保住用户写下的字，重新上传
          _adopt(merged, contents, usedNames, local,
              localContent[id] ?? const <int>[]);
          counts.addedRemote++;
        }
        continue;
      }

      if (local == null && remoteNote != null) {
        if (base == null) {
          _adopt(merged, contents, usedNames, remoteNote,
              remoteContent[id] ?? const <int>[]);
          counts.addedLocal++;
        } else if ('${remoteNote['updated'] ?? ''}' ==
            '${base['updated'] ?? ''}') {
          counts.removedRemote++;
        } else {
          _adopt(merged, contents, usedNames, remoteNote,
              remoteContent[id] ?? const <int>[]);
          counts.addedLocal++;
        }
        continue;
      }

      // 两边都有。上一段的 continue 已经排除了「只有一边」的情形，
      // 这里再判一次是为了让类型提升成立（否则 local / remoteNote 仍是可空的）。
      if (local == null || remoteNote == null) continue;
      final localBytes = localContent[id] ?? const <int>[];
      final remoteBytes = remoteContent[id] ?? const <int>[];
      final localDirty = base == null ||
          '${local['updated'] ?? ''}' != '${base['updated'] ?? ''}';
      final remoteDirty = base == null ||
          '${remoteNote['updated'] ?? ''}' != '${base['updated'] ?? ''}';

      if (!localDirty && !remoteDirty) {
        // 谁都没动：以本地为准（用户可能手工改了 md 但没动 index.json）
        _adopt(merged, contents, usedNames, local, localBytes);
        if (!_sameBytes(localBytes, remoteBytes)) counts.pushed++;
        continue;
      }
      if (localDirty && !remoteDirty) {
        _adopt(merged, contents, usedNames, local, localBytes);
        if (!_sameBytes(localBytes, remoteBytes)) counts.pushed++;
        continue;
      }
      if (!localDirty && remoteDirty) {
        _adopt(merged, contents, usedNames, remoteNote, remoteBytes);
        counts.pulled++;
        continue;
      }

      // 两边都动过
      if (_sameBytes(localBytes, remoteBytes)) {
        _adopt(merged, contents, usedNames, local, localBytes);
        continue;
      }
      final localStamp = '${local['updated'] ?? ''}';
      final remoteStamp = '${remoteNote['updated'] ?? ''}';
      final remoteWins = _newer(remoteStamp, localStamp);
      final winner = remoteWins ? remoteNote : local;
      final winnerBytes = remoteWins ? remoteBytes : localBytes;
      final loser = remoteWins ? local : remoteNote;
      final loserBytes = remoteWins ? localBytes : remoteBytes;

      _adopt(merged, contents, usedNames, winner, winnerBytes);
      if (remoteWins) {
        counts.pulled++;
      } else {
        counts.pushed++;
      }
      // 输的这份另存一篇，谁也不丢
      final copy = _conflictCopy(loser, remoteWins ? '本机副本' : '云端副本');
      _adopt(merged, contents, usedNames, copy, loserBytes);
      counts.conflicts++;
    }

    // 同名不同 id 时统一收尾，保证写盘不会互相覆盖
    _dedupeNames(merged);

    final files = collectRepoFiles(merged, contents);

    // 云端多出来的路径：只有「本地确实没有」才删，私密库没有本地副本时
    // 一律不碰（见 hasLocalVault 的注释）。
    final removals = <String>{};
    for (final path in remote.keys) {
      if (files.containsKey(path)) continue;
      if (path == indexFileName) continue;
      if (path.startsWith(vaultPrefix) && !hasLocalVault) continue;
      if (!path.startsWith(notesPrefix) && !path.startsWith(vaultPrefix)) {
        continue;
      }
      removals.add(path);
    }

    return SyncPlan(
      notes: merged,
      contents: contents,
      counts: counts,
      files: files,
      removals: removals,
      localDirty: counts.touchedLocal,
    );
  }

  /// 把合并结果落到本地磁盘。只在 [SyncPlan.localDirty] 时调用。
  void applyLocal(SyncPlan plan) {
    Directory(paths.notesDir).createSync(recursive: true);

    // 删掉被合并掉的本地文件
    final keep = <String>{
      for (final dict in plan.notes)
        if (plan.contents.containsKey('${dict['id'] ?? ''}'))
          '${dict['filename'] ?? ''}',
    };
    final dir = Directory(paths.notesDir);
    if (dir.existsSync()) {
      for (final file in dir.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.md')) continue;
        if (keep.contains(p.basename(file.path))) continue;
        try {
          file.deleteSync();
        } on FileSystemException {
          // 删不掉就留着，下次再来
        }
      }
    }

    for (final dict in plan.notes) {
      final id = '${dict['id'] ?? ''}';
      final name = '${dict['filename'] ?? ''}';
      final bytes = plan.contents[id];
      if (name.isEmpty || bytes == null) continue;
      final file = File(p.join(paths.notesDir, name));
      if (file.existsSync()) {
        try {
          if (_sameBytes(file.readAsBytesSync(), bytes)) continue;
        } on FileSystemException {
          // 读失败就直接覆盖
        }
      }
      try {
        file.writeAsBytesSync(bytes, flush: true);
      } on FileSystemException {
        // 单个文件写失败不中断整次同步
      }
    }

    File(paths.indexPath).parent.createSync(recursive: true);
    final tmp = File('${paths.indexPath}.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'version': 1,
        'notes': plan.notes,
      }),
      encoding: utf8,
    );
    tmp.renameSync(paths.indexPath);

    _saveManifest(plan.notes);
  }

  /// 提交成功后调用，把基准点更新成「云端现在也是这个状态」。
  /// 上传失败时基准点保持旧值，下次同步会重新按 dirty 判断。
  void commitManifest(SyncPlan plan) => _saveManifest(plan.notes);

  // ---------------- 内部 ----------------

  List<Map<String, dynamic>> _parseRemoteIndex(Map<String, List<int>> remote) {
    final bytes = remote[indexFileName];
    if (bytes == null || bytes.isEmpty) return const [];
    try {
      final decoded = json.decode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is! Map || decoded['notes'] is! List) return const [];
      final list = <Map<String, dynamic>>[];
      for (final item in decoded['notes'] as List) {
        if (item is! Map) continue;
        final dict = Map<String, dynamic>.from(item);
        final id = '${dict['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        dict['id'] = id;
        if ('${dict['filename'] ?? ''}'.trim().isEmpty) {
          dict['filename'] = '${slug('${dict['title'] ?? ''}')}-'
              '${id.substring(0, id.length >= 6 ? 6 : id.length)}.md';
        }
        list.add(dict);
      }
      return list;
    } on FormatException {
      return const [];
    }
  }

  void _adopt(
    List<Map<String, dynamic>> merged,
    Map<String, List<int>> contents,
    Set<String> usedNames,
    Map<String, dynamic> dict,
    List<int> bytes,
  ) {
    final id = '${dict['id'] ?? ''}';
    if (id.isEmpty) return;
    final copy = Map<String, dynamic>.from(dict);
    var name = '${copy['filename'] ?? ''}'.trim();
    if (name.isEmpty) {
      name = '${slug('${copy['title'] ?? ''}')}-'
          '${id.substring(0, id.length >= 6 ? 6 : id.length)}.md';
    }
    if (usedNames.contains(name)) {
      name = _uniqueName(name, id, usedNames);
    }
    usedNames.add(name);
    copy['filename'] = name;
    merged.add(copy);
    contents[id] = bytes;
  }

  /// 同名不同 id（两台机器上不同笔记撞了 slug）时给后面的加后缀。
  String _uniqueName(String name, String id, Set<String> used) {
    var candidate = name.isEmpty ? '${slug('未命名笔记')}-$id.md' : name;
    if (!used.contains(candidate)) return candidate;
    final stem = candidate.toLowerCase().endsWith('.md')
        ? candidate.substring(0, candidate.length - 3)
        : candidate;
    return '$stem-$id.md';
  }

  void _dedupeNames(List<Map<String, dynamic>> notes) {
    final seen = <String>{};
    for (final dict in notes) {
      var name = '${dict['filename'] ?? ''}';
      if (name.isEmpty) name = '${slug('未命名笔记')}-${newId()}.md';
      if (seen.contains(name)) {
        final stem = name.toLowerCase().endsWith('.md')
            ? name.substring(0, name.length - 3)
            : name;
        name = '$stem-${newId()}.md';
      }
      seen.add(name);
      dict['filename'] = name;
    }
  }

  Map<String, dynamic> _conflictCopy(Map<String, dynamic> dict, String suffix) {
    final copy = Map<String, dynamic>.from(dict);
    final id = newId();
    copy['id'] = id;
    copy['title'] = '${dict['title'] ?? '未命名笔记'}（$suffix）';
    copy['updated'] = '${dict['updated'] ?? isoNow()}';
    copy['filename'] = '${slug('${copy['title']}')}-${id.substring(0, 6)}.md';
    return copy;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// `YYYY-MM-DD HH:MM:SS` 直接按字典序比就是时间序。
  static bool _newer(String candidate, String reference) {
    if (candidate.isEmpty) return false;
    if (reference.isEmpty) return true;
    return candidate.compareTo(reference) > 0;
  }
}
