/// GitHub 双向同步合并引擎的单元测试。
///
/// 这里只测 [GitHubSync.merge] 的纯计算部分，不碰网络——传输层的行为
/// 在 `github_api_test.dart` 里用假服务器覆盖。合并规则是整个同步功能
/// 里最容易写错、也最容易静默丢数据的地方，所以单独拆一份：
/// 「只有一边有」「两边都改」「一边删了」三种情形各配一条用例。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/core/github_sync.dart';
import 'package:memonest/core/paths.dart';

AppPaths makePaths(String name) =>
    AppPaths(Directory.systemTemp.createTempSync('memonest-sync-$name-'));

/// 一篇笔记在 `index.json` 里的样子。
Map<String, dynamic> noteDict(String id, String title, String stamp) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      'filename': '$id.md',
      'tags': <String>[],
      'created': stamp,
      'updated': stamp,
    };

/// 造本地状态：`index.json` + 每篇的 md。
void writeLocal(AppPaths paths, List<Map<String, dynamic>> notes,
    {Map<String, String> bodies = const {}}) {
  Directory(paths.dataDir).createSync(recursive: true);
  Directory(paths.notesDir).createSync(recursive: true);
  File(paths.indexPath).writeAsStringSync(
    json.encode({'version': 1, 'notes': notes}),
    encoding: utf8,
  );
  for (final note in notes) {
    final id = '${note['id']}';
    final body = bodies[id] ?? '# ${note['title']}\n';
    File('${paths.notesDir}${Platform.pathSeparator}${note['filename']}')
        .writeAsStringSync(body, encoding: utf8);
  }
}

/// 造基准点（上次同步完成时的快照）。
void writeManifest(AppPaths paths, List<Map<String, dynamic>> notes) {
  Directory(paths.dataDir).createSync(recursive: true);
  File('${paths.dataDir}${Platform.pathSeparator}github-sync.json')
      .writeAsStringSync(
    json.encode({
      'version': 1,
      'notes': {
        for (final note in notes)
          '${note['id']}': {
            'updated': '${note['updated']}',
            'filename': '${note['filename']}',
            'title': '${note['title']}',
          },
      },
    }),
    encoding: utf8,
  );
}

/// 造云端仓库内容：`index.json` + `notes/*.md`（+ 额外文件）。
Map<String, List<int>> remoteOf(List<Map<String, dynamic>> notes,
    {Map<String, String> bodies = const {},
    Map<String, List<int>> extra = const {}}) {
  final files = <String, List<int>>{
    indexFileName: utf8.encode(json.encode({'version': 1, 'notes': notes})),
  };
  for (final note in notes) {
    final id = '${note['id']}';
    final body = bodies[id] ?? '# ${note['title']}\n';
    files['notes/${note['filename']}'] = utf8.encode(body);
  }
  files.addAll(extra);
  return files;
}

void main() {
  late AppPaths paths;

  setUp(() {
    paths = makePaths('m');
  });

  tearDown(() {
    try {
      paths.root.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略
    }
  });

  GitHubSync sync() => GitHubSync(paths);

  test('首次同步：两边取并集，谁的都不丢', () {
    final local = [noteDict('n1', '本地篇', '2026-01-01 00:00:00')];
    writeLocal(paths, local);
    // 没有基准点文件 = 第一次同步
    final plan = sync().merge(remoteOf([
      noteDict('n2', '云端篇', '2026-01-02 00:00:00'),
    ]));

    expect(plan.counts.addedRemote, 1); // 本地这篇上传
    expect(plan.counts.addedLocal, 1); // 云端这篇取回
    expect(plan.counts.removedLocal, 0);
    expect(plan.counts.removedRemote, 0);
    expect(plan.notes.length, 2);
    expect(
        plan.files.keys,
        containsAll(<String>[
          'notes/n1.md',
          'notes/n2.md',
          indexFileName,
        ]));
    expect(plan.localDirty, isTrue);
  });

  test('云端新增：本地没动，只取回新增', () {
    final base = noteDict('n1', '旧篇', '2026-01-01 00:00:00');
    writeLocal(paths, [base]);
    writeManifest(paths, [base]);

    final plan = sync().merge(remoteOf([
      base,
      noteDict('n2', '云端新篇', '2026-01-02 00:00:00'),
    ]));

    expect(plan.counts.addedLocal, 1);
    expect(plan.counts.pulled, 0);
    expect(plan.counts.removedLocal, 0);
    expect(plan.notes.map((n) => n['id']), containsAll(<String>['n1', 'n2']));
  });

  test('本地删了：云端跟着删，且只删这一篇', () {
    final base = noteDict('n1', '要删的', '2026-01-01 00:00:00');
    final keep = noteDict('n2', '留着的', '2026-01-01 00:00:00');
    // 本地只剩 n2
    writeLocal(paths, [keep]);
    writeManifest(paths, [base, keep]);

    final plan = sync().merge(
        remoteOf([base, keep], extra: {'README.md': utf8.encode('# readme')}));

    expect(plan.counts.removedRemote, 1);
    expect(plan.removals, contains('notes/n1.md'));
    expect(plan.removals, isNot(contains('notes/n2.md')));
    // 仓库里的非笔记文件不在清理范围内
    expect(plan.removals, isNot(contains('README.md')));
    expect(plan.removals, isNot(contains(indexFileName)));
  });

  test('云端删了：本地跟着删，并重写磁盘', () {
    final base = noteDict('n1', '已删除', '2026-01-01 00:00:00');
    final keep = noteDict('n2', '留着的', '2026-01-01 00:00:00');
    writeLocal(paths, [base, keep]);
    writeManifest(paths, [base, keep]);

    final plan = sync().merge(remoteOf([keep]));

    expect(plan.counts.removedLocal, 1);
    expect(plan.localDirty, isTrue);
    expect(plan.notes.map((n) => n['id']), <String>['n2']);
    expect(plan.removals, isEmpty);

    sync().applyLocal(plan);
    final left = Directory(paths.notesDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
    expect(left, <String>['n2.md']);
  });

  test('本地改过而云端删了：保住本地这一篇，重新上传', () {
    final base = noteDict('n1', '改过的', '2026-01-01 00:00:00');
    final edited = noteDict('n1', '改过的', '2026-01-05 00:00:00');
    writeLocal(paths, [edited]);
    writeManifest(paths, [base]);

    final plan = sync().merge(remoteOf(const []));

    expect(plan.counts.removedLocal, 0);
    expect(plan.counts.addedRemote, 1);
    expect(plan.notes.single['id'], 'n1');
  });

  test('两边都改：新的赢，旧的留成本机副本', () {
    final base = noteDict('n1', '同一篇', '2026-01-01 00:00:00');
    final localEdit = noteDict('n1', '同一篇', '2026-01-02 00:00:00');
    final remoteEdit = noteDict('n1', '同一篇', '2026-01-03 00:00:00');
    writeLocal(paths, [localEdit], bodies: {'n1': '# 本机改的\n'});
    writeManifest(paths, [base]);

    final plan = sync().merge(
      remoteOf([remoteEdit], bodies: {'n1': '# 云端改的\n'}),
    );

    expect(plan.counts.conflicts, 1);
    // 云端更新，所以原篇取云端的正文
    expect(plan.counts.pulled, 1);
    final winner = plan.notes.firstWhere((n) => n['id'] == 'n1');
    final winnerBytes = plan.contents['${winner['id']}'];
    expect(utf8.decode(winnerBytes!), '# 云端改的\n');
    // 本机那份变成独立的一篇，标题带后缀
    expect(plan.notes.length, 2);
    final copy = plan.notes.firstWhere((n) => n['id'] != 'n1');
    expect('${copy['title']}', contains('本机副本'));
    expect(utf8.decode(plan.contents['${copy['id']}']!), '# 本机改的\n');
  });

  test('本地没有私密库时绝不去删云端的 vault/', () {
    final base = noteDict('n1', '普通篇', '2026-01-01 00:00:00');
    writeLocal(paths, [base]);
    writeManifest(paths, [base]);

    final plan = sync().merge(remoteOf([
      base
    ], extra: {
      'vault/items/secret.mdenc': <int>[1, 2, 3],
      'vault/vault.json': utf8.encode('{"version":1}'),
    }));

    // 换台机器登录一次就把别人云端的密文抹掉，是灾难性的；
    // 这里必须一条都不删。
    expect(plan.removals.where((path) => path.startsWith('vault/')), isEmpty);
  });

  test('本地有私密库时才会清掉云端多余的密文', () {
    final base = noteDict('n1', '普通篇', '2026-01-01 00:00:00');
    writeLocal(paths, [base]);
    writeManifest(paths, [base]);
    // 本地私密库存在（只建目录就够触发 hasLocalVault）
    Directory(paths.vaultItemsDir).createSync(recursive: true);

    final plan = sync().merge(remoteOf([
      base
    ], extra: {
      'vault/items/stale.mdenc': <int>[1, 2, 3],
    }));

    expect(plan.removals, contains('vault/items/stale.mdenc'));
  });
}
