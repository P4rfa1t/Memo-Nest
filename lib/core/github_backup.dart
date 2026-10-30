/// GitHub 备份：把笔记目录变成 git 仓库并推送。
///
/// 与 Python 版 `core/backup.py` 的 `push_to_github` 同一套行为：
/// - token 只临时拼进推送 URL，绝不写进 `.git/config`
/// - 非快进时 `fetch` + `merge --allow-unrelated-histories -X ours` 后重试
/// - 私密库存在时把 `.mdenc` 密文与 `vault.json`（去掉 dpapi_key）一起汇总
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';

class GitHubError implements Exception {
  final String message;
  GitHubError(this.message);
  @override
  String toString() => message;
}

class GitHubService {
  final AppPaths paths;
  final Config config;

  GitHubService(this.paths, this.config);

  /// 推送成功返回一行可读结果。
  ///
  /// 整个过程都是异步子进程：git push 是网络往返，同步跑会把 UI isolate
  /// 卡死几秒，界面直接「无响应」。
  Future<String> push() async {
    final git = await _which('git');
    if (git == null) {
      throw GitHubError('未检测到 Git，请先安装 https://git-scm.com/download/win');
    }

    final branch = (config.get('github.branch', 'main') as String?)?.trim();
    final useBranch = (branch == null || branch.isEmpty) ? 'main' : branch;
    final url = _remoteUrl();
    final plain = _plainRemote(url);

    // vaultMetaPath 是文件（data/vault/vault.json），不是目录。原来用
    // Directory(...).existsSync() 判断，永远为 false，于是有私密库的用户
    // 也只会推 data/notes，.mdenc 密文完全没进备份。
    final hasVault = File(paths.vaultMetaPath).existsSync() ||
        Directory(paths.vaultItemsDir).existsSync();
    final workDir = hasVault
        ? _stageSource()
        : (Directory(paths.notesDir)..createSync(recursive: true));

    if (!Directory(p.join(workDir.path, '.git')).existsSync()) {
      await _git(git, ['init', '-b', useBranch], workDir);
    }
    await _git(
        git,
        [
          'config',
          'user.name',
          '${config.get('github.author_name', 'MemoNest')}',
        ],
        workDir);
    await _git(
        git,
        [
          'config',
          'user.email',
          '${config.get('github.author_email', 'memonest@localhost')}',
        ],
        workDir);

    final remotes = (await _git(git, ['remote'], workDir))
        .stdout
        .toString()
        .split(RegExp(r'\s+'));
    if (remotes.contains('origin')) {
      await _git(git, ['remote', 'set-url', 'origin', plain], workDir);
    } else {
      await _git(git, ['remote', 'add', 'origin', plain], workDir);
    }

    await _git(git, ['add', '-A'], workDir);
    final staged = await _git(git, ['diff', '--cached', '--quiet'], workDir,
        check: false);
    var committed = false;
    if (staged.exitCode != 0) {
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${now.year}-${two(now.month)}-${two(now.day)} '
          '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
      await _git(git, ['commit', '-m', '备忘录自动备份 $stamp'], workDir);
      committed = true;
    }

    var push =
        await _git(git, ['push', url, 'HEAD:$useBranch'], workDir, check: false);
    if (push.exitCode != 0) {
      final output = '${push.stderr}\n${push.stdout}'.toLowerCase();
      if (output.contains('rejected') ||
          output.contains('fetch first') ||
          output.contains('non-fast-forward')) {
        await _git(git, ['fetch', url, useBranch], workDir, check: false);
        await _git(
            git,
            [
              'merge',
              '--allow-unrelated-histories',
              '--no-edit',
              '-X',
              'ours',
              'FETCH_HEAD',
            ],
            workDir,
            check: false);
        push =
            await _git(git, ['push', url, 'HEAD:$useBranch'], workDir, check: false);
      }
      if (push.exitCode != 0) {
        final raw = '${push.stderr}'.trim().isEmpty
            ? '${push.stdout}'.trim()
            : '${push.stderr}'.trim();
        final lines =
            raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final detail = lines.isEmpty ? '推送失败' : lines.last;
        throw GitHubError('GitHub 推送失败：${_plainRemote(detail)}');
      }
    }

    final repo = (config.get('github.repo', '') as String?) ?? 'GitHub';
    return '已推送 $repo（$useBranch 分支）${committed ? '' : '，无新变更'}';
  }

  /// 拼出带 token 的推送地址。token 只在这个字符串里存在。
  String _remoteUrl() {
    final custom =
        (config.get('github.remote_url', '') as String?)?.trim() ?? '';
    final repo = (config.get('github.repo', '') as String?)?.trim() ?? '';
    final token = (config.get('github.token', '') as String?)?.trim() ?? '';
    if (custom.isNotEmpty) {
      if (custom.contains('{token}')) {
        if (token.isEmpty) throw GitHubError('请先填写 GitHub Token');
        return custom.replaceAll('{token}', token);
      }
      return custom;
    }
    final cleaned = repo.replaceAll(RegExp(r'^/+|/+$'), '');
    if (cleaned.isEmpty || !cleaned.contains('/')) {
      throw GitHubError('请填写 GitHub 仓库，格式为 用户名/仓库名');
    }
    if (token.isEmpty) throw GitHubError('请填写 GitHub Token（需要 repo 权限）');
    return 'https://x-access-token:$token@github.com/$cleaned.git';
  }

  static String _plainRemote(String url) =>
      url.replaceAll(RegExp(r'(?<=//)[^/@]+@'), '');

  /// 把普通笔记与私密库密文汇总到 `data/github`，避免污染 `data/notes`。
  Directory _stageSource() {
    final staging = Directory(p.join(paths.dataDir, 'github'))
      ..createSync(recursive: true);

    final current = <String>{};
    final notes = Directory(paths.notesDir);
    if (notes.existsSync()) {
      for (final file in notes.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.md')) continue;
        final name = p.basename(file.path);
        file.copySync(p.join(staging.path, name));
        current.add(name);
      }
    }
    for (final stale in staging.listSync().whereType<File>()) {
      final name = p.basename(stale.path);
      if (!name.toLowerCase().endsWith('.md')) continue;
      if (current.contains(name)) continue;
      try {
        stale.deleteSync();
      } on FileSystemException {
        // 忽略
      }
    }

    final itemsTarget = Directory(p.join(staging.path, 'vault', 'items'))
      ..createSync(recursive: true);
    final encrypted = <String>{};
    final items = Directory(paths.vaultItemsDir);
    if (items.existsSync()) {
      for (final file in items.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.mdenc')) continue;
        final name = p.basename(file.path);
        file.copySync(p.join(itemsTarget.path, name));
        encrypted.add(name);
      }
    }
    for (final stale in itemsTarget.listSync().whereType<File>()) {
      if (encrypted.contains(p.basename(stale.path))) continue;
      try {
        stale.deleteSync();
      } on FileSystemException {
        // 忽略
      }
    }

    final meta = File(paths.vaultMetaPath);
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
      payload.remove('dpapi_key');
      File(p.join(staging.path, 'vault', 'vault.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
        encoding: utf8,
      );
    }
    return staging;
  }

  Future<ProcessResult> _git(
    String git,
    List<String> args,
    Directory cwd, {
    bool check = true,
  }) async {
    final result = await Process.run(
      git,
      ['-c', 'credential.helper=', ...args],
      workingDirectory: cwd.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: {
        'GIT_TERMINAL_PROMPT': '0',
        'GCM_INTERACTIVE': 'never',
      },
      runInShell: false,
    );
    if (check && result.exitCode != 0) {
      final raw = '${result.stderr}'.trim().isEmpty
          ? '${result.stdout}'.trim()
          : '${result.stderr}'.trim();
      final lines = raw.split('\n').where((l) => l.trim().isNotEmpty).toList();
      throw GitHubError(
        lines.isEmpty ? 'git ${args.first} 失败' : lines.last,
      );
    }
    return result;
  }

  /// Windows 用 `where`，Linux/macOS 用 `which`；Android 上没有 git，
  /// 直接返回 null 让上层报「找不到 git」。
  static Future<String?> _which(String name) async {
    if (Platform.isAndroid) return null;
    final finder = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(finder, [name], runInShell: false);
    if (result.exitCode != 0) return null;
    final first = '${result.stdout}'
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return first.isEmpty ? null : first;
  }
}
