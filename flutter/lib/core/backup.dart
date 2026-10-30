/// 备份：本地快照 + 可选推送到 OneDrive 目录 / GitHub 仓库。
///
/// 与 Python 版 `core/backup.py` 保持同样的目录结构，备份文件可以互相恢复。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'paths.dart';

class BackupError implements Exception {
  final String message;
  BackupError(this.message);
  @override
  String toString() => message;
}

class BackupResult {
  final String path;
  final int noteCount;
  final String label;

  BackupResult({required this.path, required this.noteCount, required this.label});
}

/// 把 notes 目录打成 zip 快照，写到 backups/ 下。
///
/// 不引入 archive 依赖，手写最小 ZIP（store 模式，不压缩）——
/// 备份追求的是「能取回来」，体积换简单是划算的。
class BackupService {
  final AppPaths paths;
  final Config config;

  BackupService(this.paths, this.config);

  /// 生成一个本地快照，返回快照文件路径。
  ///
  /// 包内布局与 Python 版 `create_backup_zip` 一致：
  /// `notes/*.md`、`index.json`、`vault/items/*.mdenc`、`vault/vault.json`。
  /// 所以任意一版打出的 zip，另一版都能直接解回去。
  File createSnapshot({String label = ''}) {
    final backupDir = Directory(paths.backupDir)..createSync(recursive: true);
    final entries = <_ZipEntry>[];

    final notesDir = Directory(paths.notesDir);
    if (notesDir.existsSync()) {
      final notes = notesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in notes) {
        entries.add(_ZipEntry('notes/${p.basename(file.path)}', file.readAsBytesSync()));
      }
    }

    final index = File(paths.indexPath);
    if (index.existsSync()) {
      entries.add(_ZipEntry('index.json', index.readAsBytesSync()));
    }

    final itemsDir = Directory(paths.vaultItemsDir);
    if (itemsDir.existsSync()) {
      final items = itemsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.mdenc'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in items) {
        entries.add(
          _ZipEntry('vault/items/${p.basename(file.path)}', file.readAsBytesSync()),
        );
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
      // 机器绑定的密钥不随备份走
      payload.remove('dpapi_key');
      entries.add(_ZipEntry(
        'vault/vault.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
      ));
    }

    if (entries.isEmpty) throw BackupError('还没有任何笔记');

    final stamp = _stampNow();
    final safeLabel = label.replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '-');
    final name = safeLabel.isEmpty
        ? 'memo-backup-$stamp.zip'
        : 'memo-backup-$stamp-$safeLabel.zip';
    final target = File(p.join(backupDir.path, name));
    target.writeAsBytesSync(_buildZip(entries));
    return target;
  }

  /// 按 keep 数量清理旧备份。
  void prune({int? keep}) {
    final limit = keep ?? (config.get('general.keep_backups', 20) as num).toInt();
    if (limit <= 0) return;
    final dir = Directory(paths.backupDir);
    if (!dir.existsSync()) return;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final file in files.skip(limit)) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // 忽略
      }
    }
  }

  /// 复制到 OneDrive 文件夹（目录模式，不需要登录）。
  ///
  /// 与 Python 版 `sync_onedrive` 的文件夹分支一致：笔记镜像成明文 .md、
  /// 私密库镜像成密文，再放一份 zip 快照。返回一行可读结果。
  String? mirrorToFolder() {
    final enabled = config.get('onedrive.enabled', false) == true;
    if (!enabled) return null;
    final folder = _resolveFolder();
    if (folder == null) return null;
    final sub = (config.get('onedrive.subfolder', 'MemoNest备份') as String?) ?? '';
    final target = Directory(p.join(folder.path, sub));
    var copied = 0;
    try {
      target.createSync(recursive: true);

      if (config.get('onedrive.mirror_notes', true) == true) {
        final notesTarget = Directory(p.join(target.path, 'notes'))
          ..createSync(recursive: true);
        final source = Directory(paths.notesDir);
        final current = <String>{};
        if (source.existsSync()) {
          for (final file in source.listSync().whereType<File>()) {
            if (!file.path.toLowerCase().endsWith('.md')) continue;
            final name = p.basename(file.path);
            file.copySync(p.join(notesTarget.path, name));
            current.add(name);
            copied++;
          }
        }
        for (final stale in notesTarget.listSync().whereType<File>()) {
          if (current.contains(p.basename(stale.path))) continue;
          try {
            stale.deleteSync();
          } on FileSystemException {
            // 忽略
          }
        }

        final index = File(paths.indexPath);
        if (index.existsSync()) {
          index.copySync(p.join(target.path, 'index.json'));
        }

        // 私密库只上传密文与去掉 dpapi_key 的 vault.json
        final items = Directory(paths.vaultItemsDir);
        if (items.existsSync()) {
          final vaultTarget = Directory(p.join(target.path, 'vault'));
          final itemsTarget = Directory(p.join(vaultTarget.path, 'items'))
            ..createSync(recursive: true);
          final encrypted = <String>{};
          for (final file in items.listSync().whereType<File>()) {
            if (!file.path.toLowerCase().endsWith('.mdenc')) continue;
            final name = p.basename(file.path);
            file.copySync(p.join(itemsTarget.path, name));
            encrypted.add(name);
            copied++;
          }
          for (final stale in itemsTarget.listSync().whereType<File>()) {
            if (encrypted.contains(p.basename(stale.path))) continue;
            try {
              stale.deleteSync();
            } on FileSystemException {
              // 忽略
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
            payload.remove('dpapi_key');
            File(p.join(vaultTarget.path, 'vault.json')).writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(payload),
              encoding: utf8,
            );
          }
        }
      }

      final snapshot = createSnapshot(label: 'onedrive');
      snapshot.copySync(p.join(target.path, p.basename(snapshot.path)));
      _pruneFolder(target, int.tryParse('${config.get('onedrive.keep_backups', 30)}') ?? 30);
      return '已同步 $copied 篇笔记到 ${target.path}';
    } on FileSystemException catch (e) {
      throw BackupError('复制到 OneDrive 失败：${e.message}');
    }
  }

  /// 优先用配置里的目录，留空时自动检测常见的 OneDrive 位置。
  Directory? _resolveFolder() {
    final raw = ((config.get('onedrive.folder', '') as String?) ?? '').trim();
    if (raw.isNotEmpty) {
      final expanded = _expandVars(raw);
      final dir = Directory(expanded);
      if (!dir.existsSync()) {
        throw BackupError('OneDrive 文件夹不存在：$expanded');
      }
      return dir;
    }
    return detectOneDriveDir();
  }

  void _pruneFolder(Directory folder, int keep) {
    if (keep <= 0) return;
    final zips = folder
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final stale in zips.take(zips.length - keep < 0 ? 0 : zips.length - keep)) {
      try {
        stale.deleteSync();
      } on FileSystemException {
        // 忽略
      }
    }
  }
}

/// 展开 `%VAR%` 与开头的 `~`，与 Python 的 `expandvars().expanduser()` 对齐。
String _expandVars(String raw) {
  var out = raw;
  for (final entry in Platform.environment.entries) {
    out = out.replaceAll('%${entry.key}%', entry.value);
  }
  if (out == '~' || out.startsWith('~/') || out.startsWith(r'~\')) {
    final home = Platform.environment['USERPROFILE'] ?? '';
    out = home + out.substring(1);
  }
  return out;
}

/// 探测常见的 OneDrive 目录：`%OneDrive%` 优先，其次 `%USERPROFILE%\OneDrive`。
Directory? detectOneDriveDir() {
  final env = Platform.environment['OneDrive'];
  if (env != null && env.trim().isNotEmpty) {
    final dir = Directory(env.trim());
    if (dir.existsSync()) return dir;
  }
  final home = Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    final dir = Directory(p.join(home, 'OneDrive'));
    if (dir.existsSync()) return dir;
  }
  return null;
}

/// 一个待打包的条目：包内路径 + 内容字节。
class _ZipEntry {
  final String name;
  final List<int> data;
  const _ZipEntry(this.name, this.data);
}

/// 最小 ZIP 打包（store 模式，无压缩，UTF-8 文件名）。
///
/// Python 的 `zipfile` 能正常读 store 模式的包，所以两边互认。
List<int> _buildZip(List<_ZipEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;

  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.name);
    final data = entry.data;
    final crc = _crc32(data);

    final local = BytesBuilder()
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(0x0800)) // UTF-8 文件名
      ..add(_u16(0)) // store
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(nameBytes);
    final localBytes = local.takeBytes();
    out.add(localBytes);
    out.add(data);

    central
      ..add(_u32(0x02014b50))
      ..add(_u16(20))
      ..add(_u16(20))
      ..add(_u16(0x0800))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(data.length))
      ..add(_u16(nameBytes.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(0))
      ..add(_u32(offset))
      ..add(nameBytes);

    offset += localBytes.length + data.length;
  }

  final centralBytes = central.takeBytes();
  out.add(centralBytes);
  out
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(centralBytes.length))
    ..add(_u32(offset))
    ..add(_u16(0));

  return out.takeBytes();
}

List<int> _u16(int v) => [v & 0xff, (v >> 8) & 0xff];
List<int> _u32(int v) =>
    [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

String _stampNow([DateTime? at]) {
  final dt = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}${two(dt.month)}${two(dt.day)}'
      '-${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}
