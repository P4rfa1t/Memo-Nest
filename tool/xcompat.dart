/// 跨版本互通验证（Dart 侧）。
///
/// 用法：
///   1. Python 版先跑 `tools/xcompat.py make <dir>` 生成 vault 与一条笔记
///   2. `dart run tool/xcompat.dart <dir>` 读回来，再写一条新笔记
///   3. Python 版跑 `tools/xcompat.py verify <dir>` 检查两边都能读
library;

import 'dart:convert';
import 'dart:io';

import 'package:memonest/core/vault_store.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/xcompat.dart <vault-root>');
    exit(2);
  }
  final root = args.first;
  final password = args.length > 1 ? args[1] : 'xcompat-pass-123';

  final vault = Vault(root);
  if (!vault.exists()) {
    stderr.writeln('vault.json 不存在: $root');
    exit(1);
  }
  vault.unlock(password);
  final store = VaultStore(vault);
  final notes = store.allNotes();
  stdout.writeln('DART-READ count=${notes.length}');
  for (final note in notes) {
    stdout.writeln(
        'DART-NOTE id=${note.id} title=${note.title} content=${jsonEncode(note.content)}');
  }

  final fresh = store.create(title: '来自 Flutter', content: 'Flutter 写的私密内容');
  store.save(fresh);
  stdout.writeln('DART-WROTE id=${fresh.id}');
}
