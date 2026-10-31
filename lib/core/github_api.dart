/// GitHub 同步的 HTTP 实现：不依赖 git 可执行文件。
///
/// [GitHubService] 走本地 git 子进程，Windows/Linux 桌面没问题，
/// 但 Android 上根本没有 git 可执行文件，只能改用 API。这里用
/// Git data 接口手工拼一次提交：
///
/// 1. `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` 拿父提交
/// 2. `GET /repos/{owner}/{repo}/git/commits/{sha}` 拿父树 sha
/// 3. 递归读父树，把云端文件取回来跟本地做三方合并（见 [GitHubSync]）
/// 4. `POST /blobs` 逐个上传合并后变化过的文件（哈希未变的复用旧 blob）
/// 5. `POST /trees` 用 `base_tree` 整树重建（合并判定该删的设 `sha: null`）
/// 6. `POST /commits` + `PATCH /git/refs/heads/{branch}` 前移分支
///
/// 与 git 版的行为对齐：
/// - token 只出现在请求头里，不落到任何文件
/// - 私密库存在时把 `.mdenc` 密文与 `vault.json`（去掉 `dpapi_key`）一起传
/// - 仓库布局统一为 `notes/*.md` + `index.json` + `vault/*`，两个引擎可以互换
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

import 'github_sync.dart';
import 'paths.dart';

/// GitHub 侧的失败。文案可以直接显示给用户。
class GitApiError implements Exception {
  final String message;
  GitApiError(this.message);
  @override
  String toString() => message;
}

/// 一个待提交的文件。
class CommitFile {
  /// 仓库内路径，如 `notes/xxx.md`。
  final String path;
  final List<int> bytes;

  CommitFile(this.path, this.bytes);

  /// GitHub 的 blob sha = `sha1("blob <字节数>\\0" + 内容)`。
  ///
  /// 用它判断文件要不要重传：云端已有同 sha 的 blob 就不再 POST，
  /// 否则每次同步都要把全部便签重传一遍。
  String get blobSha {
    final header = utf8.encode('blob ${bytes.length}\u0000');
    final digest = SHA1Digest();
    digest.update(header, 0, header.length);
    final data = Uint8List.fromList(bytes);
    digest.update(data, 0, data.length);
    final out = Uint8List(digest.digestSize);
    digest.doFinal(out, 0);
    final buffer = StringBuffer();
    for (final byte in out) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class GitHubApi {
  final AppPaths paths;

  /// 覆盖 API 根地址，仅测试用。
  final String? endpointOverride;

  /// 覆盖 owner/repo 与 token，仅测试用。
  final String? repoOverride;
  final String? tokenOverride;

  GitHubApi(
    this.paths, {
    this.endpointOverride,
    this.repoOverride,
    this.tokenOverride,
  });

  static const _defaultEndpoint = 'https://api.github.com';

  String get _endpoint =>
      (endpointOverride ?? _defaultEndpoint).replaceAll(RegExp(r'/+$'), '');

  GitHubSync get _sync => GitHubSync(paths);

  /// 把笔记目录与私密库密文整理成待提交清单。
  ///
  /// 顺序固定（`notes/` → `index.json` → `vault/`），让测试和日志可复现。
  /// 内容完全取自磁盘——git 版那个 `data/github` 暂存目录是为了不污染
  /// `data/notes` 才建的，HTTP 版没有工作区概念，不需要它。
  List<CommitFile> collectFiles(Config config) {
    final sync = _sync;
    final localNotes = sync.readLocalIndex();
    final files =
        sync.collectRepoFiles(localNotes, sync.readLocalContents(localNotes));
    return [
      for (final entry in files.entries) CommitFile(entry.key, entry.value),
    ];
  }

  /// 取回云端、与本地合并、把结果落到磁盘。返回合并计划。
  ///
  /// 单独抽出来是给 git 引擎用的：它要自己做 commit，所以只借用
  /// 「取回 + 合并」这一段，之后用 git 提交磁盘上的合并结果。
  Future<SyncPlan> pullMerge(Config config) async {
    final repo = _repoOf(config);
    final token = _tokenOf(config);
    final branch = _branchOf(config);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final sync = _sync;
      final localNotes = sync.readLocalIndex();
      final localFiles =
          sync.collectRepoFiles(localNotes, sync.readLocalContents(localNotes));

      final remote = <String, List<int>>{};
      final existing = await _headTree(client, repo, token, branch);
      for (final entry in existing.entries) {
        final path = entry.key;
        if (path != indexFileName && !path.startsWith(notesPrefix)) continue;
        final localBytes = localFiles[path];
        // 本地这份跟云端同一个 blob sha，内容必然一致，省掉一次下载。
        if (localBytes != null &&
            CommitFile(path, localBytes).blobSha == entry.value) {
          remote[path] = localBytes;
          continue;
        }
        remote[path] = await _readBlob(client, repo, token, entry.value);
      }

      final plan = sync.merge(remote);
      if (plan.localDirty) sync.applyLocal(plan);
      return plan;
    } on SocketException catch (e) {
      throw GitApiError('网络连接失败：${e.message}');
    } on HandshakeException catch (e) {
      throw GitApiError('HTTPS 握手失败：${e.message}');
    } on TimeoutException {
      throw GitApiError('请求超时，请检查网络');
    } on FormatException {
      throw GitApiError('GitHub 返回的内容不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  /// 双向同步：取回云端 → 三方合并 → 提交合并结果。返回一行可读结果。
  Future<String> sync(Config config) async {
    final repo = _repoOf(config);
    final token = _tokenOf(config);
    final branch = _branchOf(config);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final sync = _sync;
      final plan = await pullMerge(config);

      // 合并之后磁盘就是最终状态，直接按它建树。
      final files = [
        for (final entry in plan.files.entries)
          CommitFile(entry.key, entry.value),
      ];

      String? parentSha;
      var treeSha = '';
      final existing = <String, String>{};
      Object? head;
      try {
        head = await _send(
            client, 'GET', '$_endpoint/repos/$repo/git/ref/heads/$branch',
            token: token);
      } on GitApiError catch (e) {
        // 404 说明分支还没建，首次提交；其余错误照抛。
        if (!e.message.contains('404')) rethrow;
        head = null;
      }
      if (head is Map) {
        final commitRef = head['object'];
        if (commitRef is Map && commitRef['sha'] is String) {
          parentSha = commitRef['sha'] as String;
          final commit = await _send(
              client, 'GET', '$_endpoint/repos/$repo/git/commits/$parentSha',
              token: token);
          final tree = commit is Map ? commit['tree'] : null;
          if (tree is Map && tree['sha'] is String) {
            treeSha = tree['sha'] as String;
            existing.addAll(await _readTree(client, repo, token, treeSha));
          }
        }
      }

      final created = <String, String>{};
      var unchanged = 0;
      for (final file in files) {
        final digest = file.blobSha;
        if (existing[file.path] == digest) {
          unchanged++;
          continue;
        }
        final blob = await _send(
          client,
          'POST',
          '$_endpoint/repos/$repo/git/blobs',
          token: token,
          body: {
            'content': base64.encode(file.bytes),
            'encoding': 'base64',
          },
        );
        final sha = blob is Map ? blob['sha'] : null;
        if (sha is! String) {
          throw GitApiError('上传 ${file.path} 后没有拿到 blob sha');
        }
        created[file.path] = sha;
      }

      // 只删合并判定该删的；`existing` 里别的东西（README、.gitignore）一律不动。
      final removed = plan.removals.where(existing.containsKey).toList();

      if (created.isEmpty && removed.isEmpty) {
        sync.commitManifest(plan);
        return plan.counts.describe(repo, branch);
      }

      final entries = <Map<String, dynamic>>[
        for (final entry in created.entries)
          {
            'path': entry.key,
            'mode': '100644',
            'type': 'blob',
            'sha': entry.value,
          },
        for (final path in removed)
          {'path': path, 'mode': '100644', 'type': 'blob', 'sha': null},
      ];
      final treeReply = await _send(
        client,
        'POST',
        '$_endpoint/repos/$repo/git/trees',
        token: token,
        body: {
          if (treeSha.isNotEmpty) 'base_tree': treeSha,
          'tree': entries,
        },
      );
      final newTree = treeReply is Map ? treeReply['sha'] : null;
      if (newTree is! String) throw GitApiError('GitHub 没有返回新的树 sha');

      final commitReply = await _send(
        client,
        'POST',
        '$_endpoint/repos/$repo/git/commits',
        token: token,
        body: {
          'message': '备忘录同步 ${_stampNow()}',
          'tree': newTree,
          'parents': parentSha == null ? <String>[] : <String>[parentSha],
          'author': {
            'name': '${config.get('github.author_name', 'MemoNest')}',
            'email':
                '${config.get('github.author_email', 'memonest@localhost')}',
            'date': DateTime.now().toUtc().toIso8601String(),
          },
        },
      );
      final commitSha = commitReply is Map ? commitReply['sha'] : null;
      if (commitSha is! String) throw GitApiError('GitHub 没有返回提交 sha');

      final refPath = '$_endpoint/repos/$repo/git/refs/heads/$branch';
      if (parentSha == null) {
        await _send(client, 'POST', '$_endpoint/repos/$repo/git/refs',
            token: token,
            body: {'ref': 'refs/heads/$branch', 'sha': commitSha});
      } else {
        await _send(client, 'PATCH', refPath,
            token: token, body: {'sha': commitSha, 'force': false});
      }

      sync.commitManifest(plan);

      final detail = <String>[
        if (plan.counts.touchedLocal || plan.counts.touchedRemote)
          plan.counts.describe(repo, branch),
        if (unchanged > 0 && created.isNotEmpty) '未变 $unchanged 个',
      ].join('；');
      return detail;
    } on SocketException catch (e) {
      throw GitApiError('网络连接失败：${e.message}');
    } on HandshakeException catch (e) {
      throw GitApiError('HTTPS 握手失败：${e.message}');
    } on TimeoutException {
      throw GitApiError('请求超时，请检查网络');
    } on FormatException {
      throw GitApiError('GitHub 返回的内容不是合法 JSON');
    } finally {
      client.close(force: true);
    }
  }

  /// 保留旧名字：外部只关心「跑一次同步」。
  Future<String> push(Config config) => sync(config);

  /// token 是否有效、目标仓库是否存在。设置页用来做「测试连接」。
  Future<String> verify(Config config) async {
    final repo = _repoOf(config);
    final token = _tokenOf(config);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final reply =
          await _send(client, 'GET', '$_endpoint/repos/$repo', token: token);
      if (reply is! Map) throw GitApiError('GitHub 返回的内容不是对象');
      final name = '${reply['full_name'] ?? repo}';
      final privacy = reply['private'] == true ? '私有' : '公开';
      return '已连接 $name（$privacy）';
    } on SocketException catch (e) {
      throw GitApiError('网络连接失败：${e.message}');
    } on HandshakeException catch (e) {
      throw GitApiError('HTTPS 握手失败：${e.message}');
    } on TimeoutException {
      throw GitApiError('请求超时，请检查网络');
    } finally {
      client.close(force: true);
    }
  }

  // ---------- 内部 ----------

  /// 分支头 → 父提交的树 → 递归展开成 `路径 -> blob sha`。
  /// 分支不存在（空仓库）时返回空表。
  Future<Map<String, String>> _headTree(
    HttpClient client,
    String repo,
    String token,
    String branch,
  ) async {
    final result = <String, String>{};
    Object? head;
    try {
      head = await _send(
          client, 'GET', '$_endpoint/repos/$repo/git/ref/heads/$branch',
          token: token);
    } on GitApiError catch (e) {
      if (!e.message.contains('404')) rethrow;
      return result;
    }
    if (head is! Map) return result;
    final commitRef = head['object'];
    if (commitRef is! Map || commitRef['sha'] is! String) return result;
    final commit = await _send(
        client, 'GET', '$_endpoint/repos/$repo/git/commits/${commitRef['sha']}',
        token: token);
    final tree = commit is Map ? commit['tree'] : null;
    if (tree is Map && tree['sha'] is String) {
      result
          .addAll(await _readTree(client, repo, token, tree['sha'] as String));
    }
    return result;
  }

  /// 递归读树，压成 `路径 -> blob sha`。
  Future<Map<String, String>> _readTree(
    HttpClient client,
    String repo,
    String token,
    String treeSha,
  ) async {
    final reply = await _send(
        client, 'GET', '$_endpoint/repos/$repo/git/trees/$treeSha?recursive=1',
        token: token);
    final result = <String, String>{};
    if (reply is Map) {
      final list = reply['tree'];
      if (list is List) {
        for (final entry in list) {
          if (entry is! Map) continue;
          if (entry['type'] != 'blob') continue;
          final path = entry['path'];
          final sha = entry['sha'];
          if (path is String && sha is String) result[path] = sha;
        }
      }
    }
    return result;
  }

  /// 取某个 blob 的内容。
  Future<List<int>> _readBlob(
    HttpClient client,
    String repo,
    String token,
    String sha,
  ) async {
    final reply = await _send(
        client, 'GET', '$_endpoint/repos/$repo/git/blobs/$sha',
        token: token);
    if (reply is! Map) return const <int>[];
    final content = reply['content'];
    if (content is! String) return const <int>[];
    try {
      return base64.decode(content.replaceAll(RegExp(r'\s'), ''));
    } on FormatException {
      return const <int>[];
    }
  }

  String _repoOf(Config config) {
    final raw = (repoOverride ?? '${config.get('github.repo', '')}').trim();
    final cleaned = raw.replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleaned.isEmpty || !cleaned.contains('/')) {
      throw GitApiError('请填写 GitHub 仓库，格式为 用户名/仓库名');
    }
    return cleaned;
  }

  String _tokenOf(Config config) {
    final token = (tokenOverride ?? '${config.get('github.token', '')}').trim();
    if (token.isEmpty) {
      throw GitApiError('请填写 GitHub Token（需要 repo 权限）');
    }
    return token;
  }

  String _branchOf(Config config) {
    final raw = '${config.get('github.branch', 'main')}'.trim();
    return raw.isEmpty ? 'main' : raw;
  }

  /// 一次请求。成功返回解码后的 JSON；失败抛 [GitApiError]。
  Future<Object?> _send(
    HttpClient client,
    String method,
    String url, {
    required String token,
    Object? body,
  }) async {
    final request = await client.openUrl(method, Uri.parse(url));
    // Authorization 必须在设 body/contentLength 之前设，否则 headers 锁死。
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    request.headers.set('User-Agent', 'MemoNest');
    if (body != null) {
      final raw = utf8.encode(json.encode(body));
      request.headers.contentType = ContentType.json;
      request.headers.contentLength = raw.length;
      request.add(raw);
    } else {
      request.headers.contentLength = 0;
    }
    final response = await request.close();
    final bytes = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    final text = utf8.decode(bytes, allowMalformed: true);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (text.trim().isEmpty) return null;
      return json.decode(text);
    }
    throw GitApiError(_errorText(text, response.statusCode));
  }

  String _errorText(String raw, int status) {
    if (status == 401) return 'Token 无效或已过期（401）';
    if (status == 404) return '仓库不存在或 Token 没有权限（404）';
    if (status == 409 || status == 422) return '云端有更新的提交，请重试（$status）';
    try {
      final decoded = json.decode(raw);
      if (decoded is Map) {
        final message = decoded['message'];
        if (message is String && message.trim().isNotEmpty) return message;
      }
    } on FormatException {
      // 落到下面的兜底
    }
    return 'HTTP $status';
  }

  static String _stampNow() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}
