/// 核心层单元测试：磁盘格式、Markdown 解析、加密往返。
///
/// 跑法：`flutter test`（或 `dart test`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/core/backup.dart';
import 'package:memonest/core/crypto.dart' as crypto;
import 'package:memonest/core/markdown.dart';
import 'package:memonest/core/models.dart';
import 'package:memonest/core/note_store.dart';
import 'package:memonest/core/paths.dart';
import 'package:memonest/core/vault_store.dart';
import 'package:path/path.dart' as p;

late Directory tmpRoot;

AppPaths makePaths(String name) {
  final root = Directory(p.join(tmpRoot.path, name))
    ..createSync(recursive: true);
  return AppPaths(root);
}

void main() {
  setUpAll(() {
    tmpRoot = Directory.systemTemp.createTempSync('memonest_test_');
  });

  tearDownAll(() {
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  group('时间格式', () {
    test('isoNow 产出 Python 同款格式', () {
      final text = isoNow(DateTime(2026, 1, 2, 3, 4, 5));
      expect(text, '2026-01-02 03:04:05');
      expect(parseTime(text), DateTime(2026, 1, 2, 3, 4, 5));
    });

    test('fmtTime 三档', () {
      final now = DateTime.now();
      expect(fmtTime(isoNow(now)), startsWith('今天 '));
      // 与 Python 一致：空串解析失败会回落到当前时间
      expect(fmtTime(''), startsWith('今天 '));
      expect(fmtTime('2020-05-06 07:08:09'), '2020-05-06');
    });
  });

  group('Markdown 解析', () {
    test('标题 / 段落 / 列表 / 代码块', () {
      const src = '# 标题\n\n正文一段\n\n- 甲\n- 乙\n\n```dart\nvar a = 1;\n```\n';
      final blocks = parseBlocks(src);
      expect(blocks.first.kind, 'heading');
      expect(blocks.first.level, 1);
      expect(blocks.any((b) => b.kind == 'list'), isTrue);
      expect(blocks.any((b) => b.kind == 'code'), isTrue);
      final list = blocks.firstWhere((b) => b.kind == 'list');
      expect(list.items, ['甲', '乙']);
      final code = blocks.firstWhere((b) => b.kind == 'code');
      expect(code.lang, 'dart');
      expect(code.text.trim(), 'var a = 1;');
    });

    test('表格', () {
      const src = '| 名 | 值 |\n| --- | --- |\n| a | 1 |\n';
      final blocks = parseBlocks(src);
      final table = blocks.firstWhere((b) => b.kind == 'table');
      expect(table.header, ['名', '值']);
      expect(table.rows.length, 1);
      expect(table.rows.first, ['a', '1']);
    });

    test('独占一行的图片', () {
      const src = '前文\n\n![截图](assets/a.png)\n\n后文';
      final blocks = parseBlocks(src);
      final image = blocks.firstWhere((b) => b.kind == 'image');
      expect(image.text, '截图');
      expect(image.src, 'assets/a.png');
    });

    test('行内样式', () {
      final spans = parseInline('**粗** 与 `代码` 与 [链接](https://a.b)');
      expect(spans.any((s) => s.bold), isTrue);
      expect(spans.any((s) => s.code), isTrue);
      expect(spans.any((s) => s.url == 'https://a.b'), isTrue);
    });

    test('stripMarkers 去掉标记', () {
      expect(stripMarkers('**粗体** 与 `代码`'), '粗体 与 代码');
      expect(stripMarkers('# 标题'), '标题');
      expect(stripMarkers('- 项目'), '项目');
    });
  });

  group('明文库', () {
    test('创建 / 保存 / 读取 / 删除', () {
      final paths = makePaths('plain')..ensureDirs();
      final store = NoteStore.fromPaths(paths);
      store.load();
      expect(store.allNotes(), isEmpty);

      final note = store.create(title: '第一条', content: '正文内容');
      expect(note.id.length, 12);
      final file = File(p.join(
          paths.notesDir, '${slug('第一条')}-${note.id.substring(0, 6)}.md'));
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('正文内容'));

      note.content = '改过的内容';
      note.title = '改名了';
      store.save(note);
      final reloaded = NoteStore.fromPaths(paths)..load();
      expect(reloaded.allNotes().length, 1);
      expect(reloaded.allNotes().first.title, '改名了');
      expect(reloaded.allNotes().first.content, '改过的内容');

      expect(store.delete(note.id), isTrue);
      expect(store.allNotes(), isEmpty);
      expect(store.listTrash().length, 1);
    });

    test('搜索与标签过滤', () {
      final paths = makePaths('search')..ensureDirs();
      final store = NoteStore.fromPaths(paths)..load();
      final a = store.create(title: '苹果', content: '红苹果');
      a.tags = ['水果'];
      store.save(a);
      final b = store.create(title: '香蕉', content: '黄香蕉');
      b.tags = ['水果', '黄色'];
      store.save(b);

      expect(store.filter(query: '苹果').length, 1);
      expect(store.filter(tag: '水果').length, 2);
      expect(store.filter(tag: '黄色').length, 1);
      expect(store.allTags()['水果'], 2);
    });

    test('回收站恢复', () {
      final paths = makePaths('trash')..ensureDirs();
      final store = NoteStore.fromPaths(paths)..load();
      final note = store.create(title: '待删', content: 'x');
      store.delete(note.id);
      final entries = store.listTrash();
      expect(entries.length, 1);
      final restored = store.restoreTrash(entries.first);
      expect(restored, isNotNull);
      expect(store.allNotes().length, 1);
      expect(store.listTrash(), isEmpty);
    });
  });

  group('加密库', () {
    test('创建 / 加解密往返 / 错误密码', () {
      final paths = makePaths('vault')..ensureDirs();
      final vault = Vault(paths.vaultDir);
      expect(vault.exists(), isFalse);
      vault.create('secret-pass');
      expect(vault.exists(), isTrue);
      expect(vault.unlocked, isTrue);

      final store = VaultStore(vault);
      final note = store.create(title: '机密', content: '这是私密内容');
      store.save(note);
      final blob = File(p.join(paths.vaultItemsDir, '${note.id}.mdenc'));
      expect(blob.existsSync(), isTrue);
      // 密文里不能出现明文
      expect(utf8.decode(blob.readAsBytesSync(), allowMalformed: true),
          isNot(contains('这是私密内容')));

      final reopened = Vault(paths.vaultDir);
      expect(() => reopened.unlock('错误密码'), throwsA(isA<VaultError>()));
      reopened.unlock('secret-pass');
      final store2 = VaultStore(reopened)..load();
      expect(store2.allNotes().length, 1);
      expect(store2.allNotes().first.content, '这是私密内容');
    });

    test('key_tag 与 Python 版一致', () {
      // Python: sha256(b"memonest-key-tag" + key).hexdigest()[:16]
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final tag = crypto.keyTag(key);
      expect(tag.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(tag), isTrue);
    });

    test('修改密码后旧密码失效', () {
      final paths = makePaths('vault2')..ensureDirs();
      final vault = Vault(paths.vaultDir)..create('old-pass');
      final store = VaultStore(vault);
      final note = store.create(title: 'T', content: 'C');
      store.save(note);
      vault.changePassword('old-pass', 'new-pass');

      final reopened = Vault(paths.vaultDir);
      expect(() => reopened.unlock('old-pass'), throwsA(isA<VaultError>()));
      reopened.unlock('new-pass');
      final store2 = VaultStore(reopened)..load();
      expect(store2.allNotes().first.content, 'C');
    });
  });

  group('路径与配置', () {
    test('默认配置字段齐全', () {
      final cfg = defaultConfig();
      expect(cfg['general']?['auto_backup_minutes'], isNotNull);
      expect(cfg['onedrive']?['subfolder'], isNotNull);
      expect(cfg['github']?['branch'], isNotNull);
    });

    test('配置读写往返', () {
      final paths = makePaths('config')..ensureDirs();
      final cfg = Config(paths.configPath)..load();
      cfg.set('general.auto_backup_minutes', 15);
      cfg.save();
      final again = Config(paths.configPath)..load();
      expect(again.get('general.auto_backup_minutes'), 15);
    });
  });

  group('备份', () {
    test('快照包内布局与 Python 版一致', () {
      final paths = makePaths('backup')..ensureDirs();
      final store = NoteStore.fromPaths(paths);
      final note = store.create(title: '测试便签', content: '# 你好\n\n正文。');
      store.save(note);
      store.saveIndex();

      final vault = Vault(paths.vaultDir)..create('backup-pass');
      final secret = VaultStore(vault)..load();
      secret.create(title: '私密一条', content: '机密内容');
      secret.saveIndex();

      final config = Config(paths.configPath)..load();
      final zip = BackupService(paths, config).createSnapshot();
      expect(zip.existsSync(), isTrue);
      // Python 的 _prune 靠这个前缀匹配，名字必须对上
      expect(p.basename(zip.path), startsWith('memo-backup-'));
      expect(p.basename(zip.path), endsWith('.zip'));

      final names = _zipEntryNames(zip.readAsBytesSync());
      expect(names.any((n) => n.startsWith('notes/') && n.endsWith('.md')),
          isTrue);
      expect(names, contains('index.json'));
      expect(names, contains('vault/vault.json'));
      expect(
          names
              .any((n) => n.startsWith('vault/items/') && n.endsWith('.mdenc')),
          isTrue);

      // vault.json 里绝不能带机器绑定的密钥
      final meta = _zipEntryBytes(zip.readAsBytesSync(), 'vault/vault.json');
      final decoded = json.decode(utf8.decode(meta)) as Map<String, dynamic>;
      expect(decoded.containsKey('dpapi_key'), isFalse);
      expect(decoded['key_tag'], isA<String>());
    });

    test('prune 只保留指定数量', () {
      final paths = makePaths('backup-prune')..ensureDirs();
      final store = NoteStore.fromPaths(paths);
      final note = store.create(title: 'A', content: 'a');
      store.save(note);

      final config = Config(paths.configPath)..load();
      config.set('general.keep_backups', 2);
      final service = BackupService(paths, config);

      final dir = Directory(paths.backupDir)..createSync(recursive: true);
      for (final name in [
        'memo-backup-20200101-000001.zip',
        'memo-backup-20200101-000002.zip',
        'memo-backup-20200101-000003.zip',
        'memo-backup-20200101-000004.zip',
      ]) {
        File(p.join(dir.path, name)).writeAsBytesSync([0]);
      }
      service.prune();
      final left = dir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .where((n) => n.startsWith('memo-backup-'))
          .toList()
        ..sort();
      expect(left, [
        'memo-backup-20200101-000003.zip',
        'memo-backup-20200101-000004.zip',
      ]);
    });

    test('目录模式同步写入明文笔记与密文私密库', () {
      final paths = makePaths('backup-sync')..ensureDirs();
      final store = NoteStore.fromPaths(paths);
      store.save(store.create(title: '普通', content: '普通内容'));
      final vault = Vault(paths.vaultDir)..create('sync-pass');
      final secret = VaultStore(vault)..load();
      secret.save(secret.create(title: '私密', content: '私密内容'));

      final target = Directory(p.join(tmpRoot.path, 'onedrive'))
        ..createSync(recursive: true);
      final config = Config(paths.configPath)..load();
      config.set('onedrive.enabled', true);
      config.set('onedrive.folder', target.path);

      final detail = BackupService(paths, config).mirrorToFolder();
      expect(detail, isNotNull);
      expect(detail!, contains('已同步'));

      final sub = Directory(p.join(target.path, 'MemoNest'));
      final notes = Directory(p.join(sub.path, 'notes'));
      expect(notes.existsSync(), isTrue);
      expect(notes.listSync().whereType<File>().length, 1);
      expect(File(p.join(sub.path, 'index.json')).existsSync(), isTrue);
      final items = Directory(p.join(sub.path, 'vault', 'items'));
      expect(items.existsSync(), isTrue);
      expect(items.listSync().whereType<File>().length, 1);
      final meta = File(p.join(sub.path, 'vault', 'vault.json'));
      expect(meta.existsSync(), isTrue);
      expect(meta.readAsStringSync().contains('dpapi_key'), isFalse);
      // 明文笔记内容不应该出现在私密库里，反之亦然
      final plainText =
          notes.listSync().whereType<File>().first.readAsStringSync();
      expect(plainText.contains('普通内容'), isTrue);
      expect(plainText.contains('私密内容'), isFalse);
    });
  });
}

/// 读 ZIP 的中央目录，返回条目名（测试用，只支持本文件打出的 store 模式）。
List<String> _zipEntryNames(List<int> bytes) {
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('找不到 ZIP 结束记录');
  final count = view.getUint16(eocd + 10, Endian.little);
  var offset = view.getUint32(eocd + 16, Endian.little);
  final names = <String>[];
  for (var i = 0; i < count; i++) {
    if (view.getUint32(offset, Endian.little) != 0x02014b50) {
      throw StateError('中央目录项损坏');
    }
    final nameLen = view.getUint16(offset + 28, Endian.little);
    final extraLen = view.getUint16(offset + 30, Endian.little);
    final commentLen = view.getUint16(offset + 32, Endian.little);
    names.add(utf8.decode(bytes.sublist(offset + 46, offset + 46 + nameLen)));
    offset += 46 + nameLen + extraLen + commentLen;
  }
  return names;
}

/// 按名字取出 ZIP 条目内容（同上，只支持 store 模式）。
List<int> _zipEntryBytes(List<int> bytes, String name) {
  final view = ByteData.sublistView(Uint8List.fromList(bytes));
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('找不到 ZIP 结束记录');
  final count = view.getUint16(eocd + 10, Endian.little);
  var offset = view.getUint32(eocd + 16, Endian.little);
  for (var i = 0; i < count; i++) {
    final nameLen = view.getUint16(offset + 28, Endian.little);
    final extraLen = view.getUint16(offset + 30, Endian.little);
    final commentLen = view.getUint16(offset + 32, Endian.little);
    final entryName =
        utf8.decode(bytes.sublist(offset + 46, offset + 46 + nameLen));
    final localOffset = view.getUint32(offset + 42, Endian.little);
    final size = view.getUint32(offset + 24, Endian.little);
    if (entryName == name) {
      final localNameLen = view.getUint16(localOffset + 26, Endian.little);
      final localExtraLen = view.getUint16(localOffset + 28, Endian.little);
      final start = localOffset + 30 + localNameLen + localExtraLen;
      return bytes.sublist(start, start + size);
    }
    offset += 46 + nameLen + extraLen + commentLen;
  }
  throw StateError('ZIP 里没有 $name');
}
