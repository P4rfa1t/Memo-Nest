/// 路径与配置：三个平台共用同一套目录布局，默认数据目录都指向 `data/`，
/// 这样同一份笔记可以在 Windows / Linux / Android 之间拷来拷去。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String appName = 'MemoNest 备忘录';
const String appVersion = '2.1.0';

/// 由 `main()` 在 Android 等「拿不到 exe 路径」的平台上提前注入。
Directory? _rootOverride;

/// Android 上必须先通过 path_provider 拿到应用私有目录再调这个。
void setAppRootOverride(Directory root) {
  _rootOverride = root;
}

/// 配置与数据的根目录。
///
/// 优先级：`MEMONEST_ROOT` 环境变量 → 注入的覆盖值 → 便携模式
/// （可执行文件旁边的 data/）→ `%LOCALAPPDATA%\Programs\MemoNest` → 可执行文件目录。
///
/// Android 没有「exe 旁边」这个概念，走注入值；`Platform.resolvedExecutable`
/// 在 Android 上指向的不是应用目录，绝不能当默认值用。
Directory resolveAppRoot() {
  final env = Platform.environment['MEMONEST_ROOT'];
  if (env != null && env.trim().isNotEmpty) {
    return Directory(env);
  }
  final override = _rootOverride;
  if (override != null) return override;

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

  /// 系统凭据托管的库密钥密文（Windows: DPAPI / Android: Keystore 包裹）。
  String get helloPath => p.join(vaultDir, 'hello.bin');
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
        'subfolder': 'MemoNest',
        'root_mode': 'appfolder',
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
      'vault': {
        // 是否允许用系统凭据验证（Windows Hello / Android 生物识别）
        // 解锁私密库，需要先用主密码解锁过一次。
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

Map<String, dynamic> _merge(
    Map<String, dynamic> base, Map<String, dynamic> override) {
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
