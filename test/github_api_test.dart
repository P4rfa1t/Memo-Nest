/// GitHub HTTP API 备份的单元测试。
///
/// 用本地 `HttpServer` 假装 GitHub，断言产出的请求真的能拼出一次合法提交：
/// blob sha 与 `git hash-object` 一致、`vault.json` 不带 `dpapi_key`、
/// 云端有而本地没有的文件被标成删除。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/core/github_api.dart';
import 'package:memonest/core/paths.dart';

/// 一次被假服务器看到的请求。
class RecordedRequest {
  final String method;
  final String path;
  final String body;

  RecordedRequest(this.method, this.path, this.body);

  @override
  String toString() => '$method $path';
}

/// 记下所有请求，并按 [handler] 决定返回码与内容。
class FakeGitHub {
  late HttpServer _server;
  final requests = <RecordedRequest>[];
  Future<(int, String)> Function(RecordedRequest request) handler =
      (request) async => (404, '{"message":"not found"}');

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final bytes = await request
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      final recorded = RecordedRequest(
        request.method,
        request.uri.toString(),
        bytes.isEmpty ? '' : utf8.decode(bytes),
      );
      requests.add(recorded);
      final (status, body) = await handler(recorded);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

AppPaths makePaths(String name) {
  final root = Directory.systemTemp.createTempSync('memonest-$name-');
  return AppPaths(root);
}

/// 写一个普通便签。
void writeNote(AppPaths paths, String name, String content) {
  Directory(paths.notesDir).createSync(recursive: true);
  File('${paths.notesDir}${Platform.pathSeparator}$name')
      .writeAsStringSync(content, encoding: utf8);
}

void main() {
  late FakeGitHub github;
  late AppPaths paths;
  late Config config;

  setUp(() async {
    github = FakeGitHub();
    await github.start();
    paths = makePaths('gh');
    config = Config(paths.configPath);
    config.set('github.repo', 'someone/notes');
    config.set('github.token', 'test-token');
  });

  tearDown(() async {
    await github.stop();
    try {
      paths.root.deleteSync(recursive: true);
    } on FileSystemException {
      // 忽略
    }
  });

  GitHubApi api() => GitHubApi(paths,
      endpointOverride: github.endpoint,
      repoOverride: 'someone/notes',
      tokenOverride: 'test-token');

  test('blob sha 与 git hash-object 一致', () {
    final bytes = utf8.encode('hello');
    final file = CommitFile('notes/a.md', bytes);
    // 参考实现：printf 'hello' | git hash-object --stdin
    expect(file.blobSha, 'b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0');
  });

  test('空内容也给出合法的 blob sha', () {
    final file = CommitFile('notes/empty.md', <int>[]);
    // printf '' | git hash-object --stdin
    expect(file.blobSha, 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391');
  });

  test('collectFiles 收集普通便签与私密库密文，并去掉 dpapi_key', () {
    writeNote(paths, 'a.md', '# A\n\n正文\n');
    writeNote(paths, 'b.md', '# B\n');
    // 非 .md 文件不该进备份。
    File('${paths.notesDir}${Platform.pathSeparator}ignore.txt')
        .writeAsStringSync('ignore');
    Directory(paths.vaultItemsDir).createSync(recursive: true);
    File('${paths.vaultItemsDir}${Platform.pathSeparator}secret.mdenc')
        .writeAsBytesSync([1, 2, 3]);
    File(paths.vaultMetaPath).writeAsStringSync(json.encode({
      'version': 1,
      'salt': 'c2FsdA==',
      'check': 'Y2hlY2s=',
      'dpapi_key': 'bm90LWZvci1iYWNrdXA=',
    }));

    final files = api().collectFiles(config);
    final names = files.map((f) => f.path).toList();

    expect(names, [
      'notes/a.md',
      'notes/b.md',
      // 索引也进仓库：同步要靠它判断「哪一篇被删了」，
      // 只传 md 的话云端的删除意图完全看不出来。
      'index.json',
      'vault/items/secret.mdenc',
      'vault/vault.json',
    ]);
    expect(names, isNot(contains('notes/ignore.txt')));

    final meta = files.last;
    final decoded =
        json.decode(utf8.decode(meta.bytes)) as Map<String, dynamic>;
    expect(decoded.containsKey('dpapi_key'), isFalse);
    expect(decoded['salt'], 'c2FsdA==');
    expect(decoded['version'], 1);
  });

  test('首次同步：建分支、上传笔记与索引、返回同步结果', () async {
    writeNote(paths, 'a.md', '# A\n');
    final blobs = <String, String>{};
    final trees = <Map<String, dynamic>>[];
    String? createdRef;

    github.handler = (request) async {
      final route = '${request.method} ${request.path}';
      if (route == 'GET /repos/someone/notes/git/ref/heads/main') {
        return (404, '{"message":"Not Found"}');
      }
      if (route == 'POST /repos/someone/notes/git/blobs') {
        final body = json.decode(request.body) as Map<String, dynamic>;
        final content = base64.decode('${body['content']}');
        final sha = CommitFile('x', content).blobSha;
        blobs[sha] = sha;
        return (201, json.encode({'sha': sha}));
      }
      if (route == 'POST /repos/someone/notes/git/trees') {
        final body = json.decode(request.body) as Map<String, dynamic>;
        trees.add(body);
        return (201, json.encode({'sha': 'tree-1'}));
      }
      if (route == 'POST /repos/someone/notes/git/commits') {
        return (201, json.encode({'sha': 'commit-1'}));
      }
      if (route == 'POST /repos/someone/notes/git/refs') {
        createdRef = request.body;
        return (201, json.encode({'ref': 'refs/heads/main'}));
      }
      return (500, '{"message":"unexpected $route"}');
    };

    final summary = await api().push(config);

    expect(summary, contains('已同步 someone/notes'));
    // 云端空，本地这篇算「上传新增」。
    expect(summary, contains('上传新增 1'));
    // 首次同步没有父树，不能带 base_tree。
    expect(trees.single.containsKey('base_tree'), isFalse);
    final entries = (trees.single['tree'] as List).cast<Map<String, dynamic>>();
    expect(
        entries.map((e) => e['path']),
        containsAll(<String>[
          'notes/a.md',
          'index.json',
        ]));
    for (final entry in entries) {
      expect(entry['sha'], isNotNull);
    }
    expect(createdRef, isNotNull);
    // 笔记 + 索引两个新 blob。
    expect(blobs.length, 2);
  });

  test('增量推送：未变文件不重传，云端多余的文件被删除', () async {
    writeNote(paths, 'keep.md', '# keep\n');
    writeNote(paths, 'new.md', '# new\n');
    final keepSha = CommitFile('x', utf8.encode('# keep\n')).blobSha;

    final posted = <String>[];
    Map<String, dynamic>? treeBody;

    github.handler = (request) async {
      final route = '${request.method} ${request.path}';
      if (route == 'GET /repos/someone/notes/git/ref/heads/main') {
        return (
          200,
          json.encode({
            'ref': 'refs/heads/main',
            'object': {'sha': 'parent-1'},
          })
        );
      }
      if (route == 'GET /repos/someone/notes/git/commits/parent-1') {
        return (
          200,
          json.encode({
            'sha': 'parent-1',
            'tree': {'sha': 'tree-0'},
          })
        );
      }
      if (route.startsWith('GET /repos/someone/notes/git/trees/tree-0')) {
        return (
          200,
          json.encode({
            'tree': [
              {'path': 'notes/keep.md', 'type': 'blob', 'sha': keepSha},
              {'path': 'notes/gone.md', 'type': 'blob', 'sha': 'old-sha'},
            ],
          })
        );
      }
      // 云端有、本地没有的笔记会被下载下来参与合并。
      if (route == 'GET /repos/someone/notes/git/blobs/old-sha') {
        return (
          200,
          json.encode({
            'content': base64.encode(utf8.encode('# gone\n')),
            'encoding': 'base64',
          })
        );
      }
      if (route == 'POST /repos/someone/notes/git/blobs') {
        final body = json.decode(request.body) as Map<String, dynamic>;
        final content = base64.decode('${body['content']}');
        final sha = CommitFile('x', content).blobSha;
        posted.add(sha);
        return (201, json.encode({'sha': sha}));
      }
      if (route == 'POST /repos/someone/notes/git/trees') {
        treeBody = json.decode(request.body) as Map<String, dynamic>;
        return (201, json.encode({'sha': 'tree-1'}));
      }
      if (route == 'POST /repos/someone/notes/git/commits') {
        return (201, json.encode({'sha': 'commit-1'}));
      }
      if (route == 'PATCH /repos/someone/notes/git/refs/heads/main') {
        return (200, json.encode({'ref': 'refs/heads/main'}));
      }
      return (500, '{"message":"unexpected $route"}');
    };

    final summary = await api().push(config);

    // keep.md 的 blob 云端已有（sha 相同直接复用本地字节，不下载），
    // 只需重传 new.md 与索引。
    expect(posted.length, 2);
    expect(posted, isNot(contains(keepSha)));
    expect(summary, contains('上传新增 2'));
    expect(summary, contains('未变 1 个'));

    expect(treeBody, isNotNull);
    expect(treeBody!['base_tree'], 'tree-0');
    final entries = (treeBody!['tree'] as List).cast<Map<String, dynamic>>();
    // 云端多出来的孤儿笔记被删掉；README 之类不在清理范围内。
    final deleted = entries.where((e) => e['sha'] == null).toList();
    expect(deleted.single['path'], 'notes/gone.md');
  });

  test('两边一致时不产生提交', () async {
    // 造一个「上次同步刚刚完成」的状态：本地 index.json、笔记、基准点
    // 三者一致，云端结构与本地完全相同。这时再同步一次应当什么都不做。
    const noteId = 'n1';
    const stamp = '2026-01-01 00:00:00';
    final note = <String, dynamic>{
      'id': noteId,
      'title': 'keep',
      'filename': 'keep.md',
      'tags': <String>[],
      'created': stamp,
      'updated': stamp,
    };
    Directory(paths.dataDir).createSync(recursive: true);
    File(paths.indexPath).writeAsStringSync(
      json.encode({
        'version': 1,
        'notes': [note],
      }),
      encoding: utf8,
    );
    writeNote(paths, 'keep.md', '# keep\n');
    File('${paths.dataDir}${Platform.pathSeparator}github-sync.json')
        .writeAsStringSync(
      json.encode({
        'version': 1,
        'notes': {
          noteId: {'updated': stamp, 'filename': 'keep.md', 'title': 'keep'},
        },
      }),
      encoding: utf8,
    );

    // 云端树直接用本地产出的那份，sha 必然对得上。
    final localFiles = api().collectFiles(config);
    final remoteTree = <Map<String, dynamic>>[
      for (final file in localFiles)
        {'path': file.path, 'type': 'blob', 'sha': file.blobSha},
    ];

    var commits = 0;
    var uploads = 0;

    github.handler = (request) async {
      final route = '${request.method} ${request.path}';
      if (route == 'GET /repos/someone/notes/git/ref/heads/main') {
        return (
          200,
          json.encode({
            'object': {'sha': 'parent-1'},
          })
        );
      }
      if (route == 'GET /repos/someone/notes/git/commits/parent-1') {
        return (
          200,
          json.encode({
            'tree': {'sha': 'tree-0'},
          })
        );
      }
      if (route.startsWith('GET /repos/someone/notes/git/trees/tree-0')) {
        return (200, json.encode({'tree': remoteTree}));
      }
      if (route == 'POST /repos/someone/notes/git/blobs') {
        uploads++;
        return (201, json.encode({'sha': 'unexpected'}));
      }
      if (route == 'POST /repos/someone/notes/git/commits') {
        commits++;
        return (201, json.encode({'sha': 'commit-1'}));
      }
      return (500, '{"message":"unexpected $route"}');
    };

    final summary = await api().push(config);
    expect(uploads, 0);
    expect(commits, 0);
    expect(summary, contains('已是最新'));
  });

  test('401 与 404 给出中文提示', () async {
    writeNote(paths, 'a.md', '# A\n');
    github.handler = (request) async => (401, '{"message":"Bad credentials"}');
    await expectLater(
      api().push(config),
      throwsA(isA<GitApiError>()
          .having((e) => e.message, 'message', contains('401'))),
    );

    github.handler = (request) async => (404, '{"message":"Not Found"}');
    await expectLater(
      api().push(config),
      throwsA(isA<GitApiError>()
          .having((e) => e.message, 'message', contains('404'))),
    );
  });

  test('仓库或令牌缺失时在本地就拦下来', () async {
    // 不带 override：repo/token 一律读 config，才能验证本地校验。
    final local = GitHubApi(paths, endpointOverride: github.endpoint);
    config.set('github.repo', '');
    await expectLater(
      local.push(config),
      throwsA(isA<GitApiError>()
          .having((e) => e.message, 'message', contains('用户名/仓库名'))),
    );

    config.set('github.repo', 'someone/notes');
    config.set('github.token', '');
    await expectLater(
      local.push(config),
      throwsA(isA<GitApiError>()
          .having((e) => e.message, 'message', contains('Token'))),
    );
  });

  test('verify 报告仓库名与可见性', () async {
    github.handler = (request) async {
      if (request.path == '/repos/someone/notes') {
        return (
          200,
          json.encode({
            'full_name': 'someone/notes',
            'private': true,
          })
        );
      }
      return (404, '{"message":"Not Found"}');
    };
    final detail = await api().verify(config);
    expect(detail, contains('someone/notes'));
    expect(detail, contains('私有'));
  });
}
