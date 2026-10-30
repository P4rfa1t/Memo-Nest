/// 路径与配置：与 Python 版 `core/config.py` 同一套目录布局，
/// 默认数据目录也指向 `data/`，这样两个版本可以共用同一份笔记。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String appName = 'MemoNest 备忘录';
const String appVersion = '2.0.0';

/// 配置与数据的根目录。
///
/// 优先级：`MEMONEST_ROOT` 环境变量 → 便携模式（exe 旁边的 data/）→
/// `%LOCALAPPDATA%\Programs\MemoNest`（与安装版一致）。
/// Python 版是「exe 旁边」，这里保持同样的语义，用户把两个版本放同一目录
/// 就能直接共用 data/。
Directory resolveAppRoot() {
  final env = Platform.environment['MEMONEST_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    return Directory(env);
  }
  final exeDir = File(Platform.resolvedExecutable).parent;
  final beside = Directory(p.join(exeDir.path, 'data'));
  if (beside.existsSync()) {
    return exeDir;
  }
  final localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    final installed = Directory(p.join(localAppData, 'Programs', 'MemoNest'));
    if (installed.existsSync()) {
      return installed;
    }
  }
  return exeDir;
}

class AppPaths {
  final Directory root;

  AppPaths([Directory? root]) : root = root ?? resolveAppRoot();

  String get rootPath => root.path;
  String get configPath => p.join(rootPath, 'config.json');
  String get dataDir => p.join(rootPath, 'data');
  String get notesDir => p.join(dataDir, 'notes');
  String get assetsDir => p.join(notesDir, 'assets');
  String get trashDir => p.join(dataDir, 'trash');
  String get backupDir => p.join(dataDir, 'backups');
  String get vaultDir => p.join(dataDir, 'vault');
  String get vaultItemsDir => p.join(vaultDir, 'items');
  String get vaultTrashDir => p.join(vaultDir, 'trash');
  String get vaultMetaPath => p.join(vaultDir, 'vault.json');
  String get indexPath => p.join(dataDir, 'index.json');
  String get logPath => p.join(dataDir, 'memo.log');

  void ensureDirs() {
    for (final dir in [dataDir, notesDir, trashDir, backupDir]) {
      Directory(dir).createSync(recursive: true);
    }
  }
}

/// 与 Python 版 `DEFAULTS` 完全对应的默认配置。
Map<String, dynamic> defaultConfig() => {
      'onedrive': {
        'enabled': false,
        'mode': 'folder',
        'folder': '',
        'subfolder': 'MemoNest备份',
        'mirror_notes': true,
        'keep_backups': 30,
        'client_id': '',
        'tenant': 'common',
        'access_token': '',
        'refresh_token': '',
        'expires_at': 0,
        'account': '',
      },
      'github': {
        'enabled': false,
        'repo': '',
        'branch': 'main',
        'token': '',
        'remote_url': '',
        'author_name': 'MemoNest',
        'author_email': 'memonest@localhost',
      },
      'general': {
        'autostart': false,
        'auto_backup_minutes': 0,
        'backup_on_exit': true,
        'keep_backups': 20,
        'window_geometry': '',
        'always_on_top': false,
        'hello_unlock': true,
      },
    };

/// 点号路径配置，`get("onedrive.enabled")` 这样访问。
class Config {
  final String path;
  Map<String, dynamic> data = defaultConfig();

  Config(this.path) {
    load();
  }

  void load() {
    final file = File(path);
    if (!file.existsSync()) return;
    try {
      final raw = json.decode(file.readAsStringSync());
      if (raw is Map) {
        data = _merge(defaultConfig(), Map<String, dynamic>.from(raw));
      }
    } on FormatException {
      // 配置坏了就用默认值，和 Python 版一致
    } on FileSystemException {
      // 读不到同理
    }
  }

  void save() {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(data),
      encoding: utf8,
    );
    tmp.renameSync(path);
  }

  dynamic get(String dotted, [dynamic fallback]) {
    dynamic current = data;
    for (final part in dotted.split('.')) {
      if (current is! Map || !current.containsKey(part)) return fallback;
      current = current[part];
    }
    return current;
  }

  void set(String dotted, dynamic value) {
    final parts = dotted.split('.');
    var current = data;
    for (final part in parts.take(parts.length - 1)) {
      final node = current[part];
      if (node is Map<String, dynamic>) {
        current = node;
      } else {
        final created = <String, dynamic>{};
        current[part] = created;
        current = created;
      }
    }
    current[parts.last] = value;
  }
}

Map<String, dynamic> _merge(Map<String, dynamic> base, Map<String, dynamic> override) {
  for (final entry in override.entries) {
    final existing = base[entry.key];
    final incoming = entry.value;
    if (existing is Map && incoming is Map) {
      base[entry.key] = _merge(
        Map<String, dynamic>.from(existing),
        Map<String, dynamic>.from(incoming),
      );
    } else {
      base[entry.key] = incoming;
    }
  }
  return base;
}
