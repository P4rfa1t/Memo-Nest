/// Windows 集成：开机自启（HKCU Run 项）与桌面快捷方式。
///
/// 走 `reg.exe` / PowerShell 的 COM 调用而不是自己写 FFI：
/// 这两件事一次只做一次，进程启动开销无关紧要，代码可读性更重要。
library;

import 'dart:io';

const String _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String _valueName = 'MemoNest';

/// 开机自启要执行的命令行。冻结后的 exe 直接写自身路径。
String launchCommand() => '"${Platform.resolvedExecutable}"';

bool get autostartSupported => Platform.isWindows;

/// 读注册表判断当前是否已启用（值必须与 [launchCommand] 完全一致）。
bool autostartEnabled() {
  if (!autostartSupported) return false;
  final result = Process.runSync(
      'reg',
      [
        'query',
        _runKey,
        '/v',
        _valueName,
      ],
      runInShell: false);
  if (result.exitCode != 0) return false;
  final text = '${result.stdout}';
  final match = RegExp(r'REG_SZ\s+(.+)$', multiLine: true).firstMatch(text);
  if (match == null) return false;
  return match.group(1)!.trim() == launchCommand();
}

/// 写入或删除 Run 项。抛 [WindowsShellError] 表示失败。
void setAutostart(bool enabled) {
  if (!autostartSupported) {
    throw const WindowsShellError('开机自启仅支持 Windows');
  }
  final result = enabled
      ? Process.runSync(
          'reg',
          [
            'add',
            _runKey,
            '/v',
            _valueName,
            '/t',
            'REG_SZ',
            '/d',
            launchCommand(),
            '/f',
          ],
          runInShell: false)
      : Process.runSync(
          'reg',
          [
            'delete',
            _runKey,
            '/v',
            _valueName,
            '/f',
          ],
          runInShell: false);
  // 删除一个本来就不存在的值会返回非 0，这不算错。
  if (!enabled) return;
  if (result.exitCode != 0) {
    throw WindowsShellError('写入注册表失败：${result.stderr}');
  }
}

/// 在桌面创建快捷方式，返回 .lnk 的完整路径。
String createDesktopShortcut() {
  if (!autostartSupported) {
    throw const WindowsShellError('仅支持 Windows');
  }
  final script = '''
\$desktop = [Environment]::GetFolderPath('Desktop')
\$lnk = Join-Path \$desktop 'MemoNest 备忘录.lnk'
\$shell = New-Object -ComObject WScript.Shell
\$sc = \$shell.CreateShortcut(\$lnk)
\$sc.TargetPath = '${Platform.resolvedExecutable}'
\$sc.WorkingDirectory = '${File(Platform.resolvedExecutable).parent.path}'
\$sc.IconLocation = '${Platform.resolvedExecutable},0'
\$sc.Description = 'MemoNest 备忘录'
\$sc.Save()
Write-Output \$lnk
''';
  final result = Process.runSync(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
      runInShell: false);
  if (result.exitCode != 0) {
    throw WindowsShellError('创建快捷方式失败：${result.stderr}');
  }
  final path = '${result.stdout}'.trim();
  if (path.isEmpty) {
    throw const WindowsShellError('创建快捷方式失败：没有返回路径');
  }
  return path;
}

class WindowsShellError implements Exception {
  final String message;
  const WindowsShellError(this.message);

  @override
  String toString() => message;
}
