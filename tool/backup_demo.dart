/// 跨版本备份互通验证（Dart 侧）。
///
/// 在指定目录建一份示例数据（普通便签 + 私密便签），打一个 zip 快照，
/// 再把 OneDrive 目录模式同步也跑一遍。之后用 Python 的 zipfile 读回来，
/// 确认两边包内布局一致。
///
/// 用法：`dart run tool/backup_demo.dart <root-dir>`
library;

import 'dart:io';

import 'package:memonest/core/backup.dart';
import 'package:memonest/core/note_store.dart';
import 'package:memonest/core/paths.dart';
import 'package:memonest/core/vault_store.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/backup_demo.dart <root-dir>');
    exit(2);
  }
  final root = Directory(args.first);
  if (root.existsSync()) root.deleteSync(recursive: true);
  root.createSync(recursive: true);

  final paths = AppPaths(root)..ensureDirs();

  final store = NoteStore.fromPaths(paths);
  store.save(store.create(title: '普通便签', content: '# 普通\n\n这是明文内容。'));

  final vault = Vault(paths.vaultDir)..create('backup-pass-123');
  final secret = VaultStore(vault)..load();
  secret.save(secret.create(title: '私密便签', content: '这是密文内容。'));

  final config = Config(paths.configPath)..load();

  final zip = BackupService(paths, config).createSnapshot();
  stdout.writeln('DART-ZIP ${zip.path} ${zip.lengthSync()}');

  final mirrorRoot = Directory('${root.path}/onedrive')
    ..createSync(recursive: true);
  config.set('onedrive.enabled', true);
  config.set('onedrive.folder', mirrorRoot.path);
  final detail = BackupService(paths, config).mirrorToFolder();
  stdout.writeln('DART-MIRROR $detail');
}
