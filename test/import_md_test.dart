import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/core/note_store.dart';
import 'package:memonest/core/paths.dart';
import 'package:memonest/core/store_api.dart';
import 'package:path/path.dart' as p;

/// 造一个独立的 AppPaths，避免碰到真实数据目录。
AppPaths makePaths(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  return AppPaths(root);
}

/// 与 `_importNotes()` 里逐文件导入的逻辑保持一致。
NotesStore importFiles(NotesStore store, List<String> paths) {
  for (final path in paths) {
    final content = File(path).readAsStringSync(encoding: utf8);
    final fallback = p.basenameWithoutExtension(path);
    final title = guessTitle(content, fallback);
    store.create(title: title, content: content);
  }
  return store;
}

void main() {
  group('导入 Markdown', () {
    test('标题取第一个标题行，正文原样保留', () {
      final paths = makePaths('import_md_title');
      final store = NoteStore.fromPaths(paths);
      final src = File(p.join(paths.dataDir, 'src1.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# 项目周报\n\n本周做了三件事。\n', encoding: utf8);

      importFiles(store, [src.path]);

      final note = store.allNotes().single;
      expect(note.title, '项目周报');
      // 正文一字不改：`# 项目周报` 那行还在。
      expect(note.content, '# 项目周报\n\n本周做了三件事。\n');
    });

    test('没有标题行就取第一行前 60 字', () {
      final paths = makePaths('import_md_plain');
      final store = NoteStore.fromPaths(paths);
      final src = File(p.join(paths.dataDir, 'src2.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('随手记的一句话\n第二行\n', encoding: utf8);

      importFiles(store, [src.path]);

      expect(store.allNotes().single.title, '随手记的一句话');
    });

    test('空文件退回文件名当标题', () {
      final paths = makePaths('import_md_empty');
      final store = NoteStore.fromPaths(paths);
      final src = File(p.join(paths.dataDir, '我的会议记录.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('', encoding: utf8);

      importFiles(store, [src.path]);

      expect(store.allNotes().single.title, '我的会议记录');
    });

    test('多文件各自成为独立便签', () {
      final paths = makePaths('import_md_multi');
      final store = NoteStore.fromPaths(paths);
      final a = File(p.join(paths.dataDir, 'a.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# 甲\n正文甲\n', encoding: utf8);
      final b = File(p.join(paths.dataDir, 'b.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# 乙\n正文乙\n', encoding: utf8);

      importFiles(store, [a.path, b.path]);

      final titles = store.allNotes().map((n) => n.title).toList()..sort();
      expect(titles, ['乙', '甲']);
      expect(store.allNotes(), hasLength(2));
    });

    test('正文里的标签和代码块不被拆坏', () {
      final paths = makePaths('import_md_rich');
      final store = NoteStore.fromPaths(paths);
      const body = '# T\n\n```dart\nfinal a = "# 不是标题";\n```\n\n- [ ] 待办\n';
      final src = File(p.join(paths.dataDir, 'c.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync(body, encoding: utf8);

      importFiles(store, [src.path]);

      expect(store.allNotes().single.content, body);
      expect(store.allNotes().single.title, 'T');
    });
  });
}
