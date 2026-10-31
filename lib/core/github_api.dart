/// GitHub 备份的 HTTP 实现：不依赖 git 可执行文件。
///
/// [GitHubService] 走本地 git 子进程，Windows/Linux 桌面没问题，
/// 但 Android 上根本没有 git 可执行文件，只能改用 API。这里用
/// Git data 接口手工拼一次提交：
///
/// 1. `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` 拿父提交
/// 2. `GET /repos/{owner}/{repo}/git/commits/{sha}` 拿父树 sha
/// 3. `POST /blobs` 逐个上传改动过的文件（哈希未变的复用旧 blob）
/// 4. `POST /trees` 用 `base_tree` 整树重建（清单里没有的自动删除）
/// 5. `POST /commits` + `PATCH /git/refs/heads/{branch}` 前移分支
///
/// 与 git 版的行为对齐：
/// - token 只出现在请求头里，不落到任何文件
/// - 私密库存在时把 `.mdenc` 密文与 `vault.json`（去掉 `dpapi_key`）一起传
/// - 云端清单之外的旧文件被删除，避免删掉的便签一直留着
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha1.dart';

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

  /// GitHub 的 blob sha = `sha1("blob <字节数>\0" + 内容)`。
  ///
  /// 用它判断文件要不要重传：云端已有同 sha 的 blob 就不再 POST，
  /// 否则每次备份都要把全部便签重传一遍。
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

  /// 把笔记目录与私密库密文整理成待提交清单。
  ///
  /// 顺序固定（`notes/` 在前、`vault/` 在后，各自按文件名排序），
  /// 让测试和日志可复现。内容完全取自磁盘——git 版那个 `data/github`
  /// 暂存目录是为了不污染 `data/notes` 才建的，HTTP 版没有工作区概念，
  /// 不需要它。
  List<CommitFile> collectFiles(Config config) {
    final files = <CommitFile>[];
    final notes = Directory(paths.notesDir);
    if (notes.existsSync()) {
      final pathsList = notes
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path.toLowerCase().endsWith('.md'))
          .toList()
        ..sort();
      for (final path in pathsList) {
        files.add(CommitFile(
          'notes/${_basename(path)}',
          File(path).readAsBytesSync(),
        ));
      }
    }

    final meta = File(paths.vaultMetaPath);
    final items = Directory(paths.vaultItemsDir);
    if (items.existsSync()) {
      final pathsList = items
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((path) => path.toLowerCase().endsWith('.mdenc'))
          .toList()
        ..sort();
      for (final path in pathsList) {
        files.add(CommitFile(
          'vault/items/${_basename(path)}',
          File(path).readAsBytesSync(),
        ));
      }
    }
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
      // 与 git 版一致：这台机器的密钥材料绝不进备份。
      payload.remove('dpapi_key');
      files.add(CommitFile(
        'vault/vault.json',
        utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
      ));
    }
    return files;
  }

  /// 提交并推送。返回一行可读结果。
  Future<String> push(Config config) async {
    final repo = _repoOf(config);
    final token = _tokenOf(config);
    final branch = _branchOf(config);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final files = collectFiles(config);

      // 分支还不存在时（空仓库）没有父提交，走首次提交。
      String? parentSha;
      var treeSha = '';
      final existing = <String, String>{};
      Object? head;
      try {
        head = await _send(
            client, 'GET', '$_endpoint/repos/$repo/git/ref/heads/$branch',
            token: token);
      } on GitApiError catch (e) {
        // 404 说明分支还没建，首次推送；其余错误照抛。
        if (!e.message.startsWith('HTTP 404') && !e.message.contains('404')) {
          rethrow;
        }
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
      final unchanged = <String>[];
      final planned = <String>{};
      for (final file in files) {
        planned.add(file.path);
        final digest = file.blobSha;
        if (existing[file.path] == digest) {
          unchanged.add(file.path);
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

      // 云端有、本次清单没有的，一律标成删除，否则删掉的便签会一直留着。
      final removed =
          existing.keys.where((path) => !planned.contains(path)).toList();

      if (created.isEmpty && removed.isEmpty) {
        return '已是最新（$repo $branch 分支）';
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
          'message': '备忘录自动备份 ${_stampNow()}',
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

      final parts = <String>[];
      if (created.isNotEmpty) parts.add('上传 ${created.length} 个文件');
      if (removed.isNotEmpty) parts.add('删除 ${removed.length} 个');
      if (unchanged.isNotEmpty) parts.add('未变 ${unchanged.length} 个');
      if (parts.isEmpty) parts.add('无变更');
      return '已推送 $repo（$branch 分支）：${parts.join('，')}';
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

  /// 递归读父树，压成 `路径 -> blob sha`。
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

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
}
