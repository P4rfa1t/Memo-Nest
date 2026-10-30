/// 各平台宿主的具体实现。
///
/// 用运行时分支而不是条件导入：三个平台都是原生 Dart VM，`dart:io` 与
/// `dart:ffi` 都可用，差别只在「调不调某个插件」——那种情况靠根本不调用规避。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/paths.dart';
import 'clipboard_image.dart' as win_clipboard;
import 'dpapi.dart' as dpapi;
import 'host.dart';
import 'windows_shell.dart' as win_shell;

/// 当前平台的宿主实现。
Host createHost(AppPaths paths) {
  if (Platform.isWindows) return WindowsHost(paths);
  if (Platform.isAndroid) return AndroidHost(paths);
  if (Platform.isLinux) return LinuxHost(paths);
  return PlainHost(paths);
}

/// 兜底实现，也是另外三个的基类：一切「平台特有」都先按不支持处理。
class PlainHost implements Host {
  final AppPaths paths;

  PlainHost(this.paths);

  @override
  bool get isDesktop => false;
  @override
  bool get autostartSupported => false;
  @override
  bool get shortcutSupported => false;
  @override
  bool get clipboardImageSupported => false;
  @override
  bool get deviceAuthSupported => false;
  @override
  bool get secretSupported => false;

  @override
  Future<void> initWindow() async {}
  @override
  Future<void> applyWindowPrefs({
    required bool alwaysOnTop,
    required String geometry,
  }) async {}
  @override
  Future<void> destroyWindow() async {}
  @override
  Future<void> setAlwaysOnTop(bool value) async {}
  @override
  Future<void> minimize() async {}
  @override
  Future<void> toggleMaximize() async {}
  @override
  Future<void> closeWindow() async {}
  @override
  Future<bool> isMaximized() async => false;
  @override
  Future<String?> currentGeometry() async => null;
  @override
  VoidCallback addWindowListener({
    required VoidCallback onMaximize,
    required VoidCallback onUnmaximize,
    required Future<void> Function() onClose,
  }) =>
      () {};

  @override
  bool autostartEnabled() => false;
  @override
  void setAutostart(bool enabled) =>
      throw HostError('当前平台不支持开机自启');

  @override
  String createDesktopShortcut() =>
      throw HostError('当前平台不支持创建桌面快捷方式');

  @override
  @override
  Future<bool> openFolder(String path) async => false;

  @override
  bool get titleBarDragInDart => false;

  @override
  Future<void> startWindowDrag() async {}

  @override
  String get authLabel => '系统验证';

  @override
  String get authShort => '系统验证';

  @override
  bool clipboardHasImage() => false;
  @override
  ClipboardBitmap? readClipboardBitmap() => null;

  @override
  Future<bool> deviceAuthAvailable() async => false;
  @override
  Future<bool> deviceAuthVerify({String prompt = '解锁私密笔记库'}) async =>
      false;
  @override
  Future<Uint8List> protectSecret(Uint8List plain,
          {String description = 'MemoNest 私密库'}) async =>
      throw const HostError('当前平台不支持托管解锁凭据');
  @override
  Future<Uint8List> unprotectSecret(Uint8List blob) async =>
      throw const HostError('当前平台不支持托管解锁凭据');
}

// ---------------- 桌面窗口公共部分 ----------------

/// Windows 与 Linux 共用 window_manager 的那一套。
mixin _DesktopWindow on PlainHost {
  @override
  bool get isDesktop => true;

  @override
  Future<void> initWindow() async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(456, 679),
      minimumSize: Size(380, 420),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'MemoNest 备忘录',
      skipTaskbar: false,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  @override
  Future<void> applyWindowPrefs({
    required bool alwaysOnTop,
    required String geometry,
  }) async {
    await windowManager.setAlwaysOnTop(alwaysOnTop);
    final match =
        RegExp(r'^(\d+)x(\d+)([+-]\d+)([+-]\d+)?$').firstMatch(geometry);
    if (match == null) return;
    final w = int.tryParse(match.group(1) ?? '');
    final h = int.tryParse(match.group(2) ?? '');
    final x = int.tryParse(match.group(3) ?? '');
    final y = int.tryParse(match.group(4) ?? '');
    if (w == null || h == null || w < 380 || h < 420) return;
    await windowManager.setSize(Size(w.toDouble(), h.toDouble()));
    if (x != null && y != null) {
      await windowManager.setPosition(Offset(x.toDouble(), y.toDouble()));
    }
  }

  @override
  bool get titleBarDragInDart => false;

  @override
  Future<void> startWindowDrag() => windowManager.startDragging();

  @override
  Future<bool> openFolder(String path) async {
    final command = Platform.isWindows ? 'explorer.exe' : 'xdg-open';
    try {
      await Process.run(command, [path]);
      return true;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<void> destroyWindow() => windowManager.destroy();

  @override
  Future<void> setAlwaysOnTop(bool value) =>
      windowManager.setAlwaysOnTop(value);
  @override
  Future<void> minimize() => windowManager.minimize();
  @override
  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> closeWindow() => windowManager.close();
  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<String?> currentGeometry() async {
    // 最大化状态下 getSize 返回的是最大化后的尺寸，记下来会让下次启动
    // 打开成一个「比屏幕还大」的普通窗口，所以还原一次再取。
    if (await windowManager.isMaximized()) await windowManager.unmaximize();
    final size = await windowManager.getSize();
    final pos = await windowManager.getPosition();
    return '${size.width.round()}x${size.height.round()}'
        '${pos.dx >= 0 ? '+' : ''}${pos.dx.round()}'
        '${pos.dy >= 0 ? '+' : ''}${pos.dy.round()}';
  }

  _HostWindowListener? _listener;

  @override
  VoidCallback addWindowListener({
    required VoidCallback onMaximize,
    required VoidCallback onUnmaximize,
    required Future<void> Function() onClose,
  }) {
    final listener = _HostWindowListener(
      onMaximize: onMaximize,
      onUnmaximize: onUnmaximize,
      onClose: onClose,
    );
    _listener = listener;
    windowManager.addListener(listener);
    return () {
      windowManager.removeListener(listener);
      if (identical(_listener, listener)) _listener = null;
    };
  }
}

class _HostWindowListener extends WindowListener {
  final VoidCallback onMaximize;
  final VoidCallback onUnmaximize;
  final Future<void> Function() onClose;

  _HostWindowListener({
    required this.onMaximize,
    required this.onUnmaximize,
    required this.onClose,
  });

  @override
  void onWindowMaximize() => onMaximize();
  @override
  void onWindowUnmaximize() => onUnmaximize();
  @override
  void onWindowClose() => onClose();
}

// ---------------- Windows ----------------

/// Windows：window_manager + 注册表/PowerShell + CF_DIB + DPAPI/Hello。
class WindowsHost extends PlainHost with _DesktopWindow {
  WindowsHost(super.paths);

  @override
  bool get autostartSupported => win_shell.autostartSupported;
  @override
  bool get shortcutSupported => true;
  @override
  bool get clipboardImageSupported => true;
  @override
  bool get deviceAuthSupported => true;
  @override
  bool get secretSupported => true;

  @override
  bool autostartEnabled() => win_shell.autostartEnabled();

  @override
  void setAutostart(bool enabled) {
    try {
      win_shell.setAutostart(enabled);
    } on win_shell.WindowsShellError catch (e) {
      throw HostError(e.message);
    }
  }

  @override
  String createDesktopShortcut() {
    try {
      return win_shell.createDesktopShortcut();
    } on win_shell.WindowsShellError catch (e) {
      throw HostError(e.message);
    }
  }

  @override
  @override
  String get authLabel => 'Windows Hello';

  @override
  String get authShort => 'PIN / 指纹 / 面容';

  @override
  bool clipboardHasImage() => win_clipboard.clipboardHasImage();

  @override
  ClipboardBitmap? readClipboardBitmap() {
    final bitmap = win_clipboard.readClipboardBitmap();
    if (bitmap == null) return null;
    return ClipboardBitmap(
        bitmap.width, bitmap.height, bitmap.bitCount, bitmap.pixels);
  }

  @override
  Future<bool> deviceAuthAvailable() =>
      _helloChannel('available').then((v) => v == true);

  @override
  Future<bool> deviceAuthVerify({String prompt = '解锁私密笔记库'}) =>
      _helloChannel('authenticate', {'prompt': prompt}).then((v) => v == true);

  @override
  Future<Uint8List> protectSecret(Uint8List plain,
      {String description = 'MemoNest 私密库'}) async {
    try {
      return dpapi.dpapiProtect(plain, description: description);
    } on dpapi.DpapiError catch (e) {
      throw HostError(e.message);
    }
  }

  @override
  Future<Uint8List> unprotectSecret(Uint8List blob) async {
    try {
      return dpapi.dpapiUnprotect(blob);
    } on dpapi.DpapiError catch (e) {
      throw HostError(e.message);
    }
  }
}

/// Windows 与 Android 共用 `memonest/hello` 通道，只是原生实现不同。
Future<Object?> _helloChannel(String method,
    [Map<String, dynamic>? arguments]) async {
  try {
    return await const MethodChannel('memonest/hello')
        .invokeMethod<Object?>(method, arguments);
  } on PlatformException catch (e) {
    throw HostError(e.message ?? '系统验证调用失败');
  } on MissingPluginException {
    throw const HostError('当前平台没有系统验证实现');
  }
}

// ---------------- Linux ----------------

/// Linux：window_manager 有 X11/Wayland 实现，自启走 XDG autostart。
///
/// 剪贴板位图与系统凭据验证没有跨桌面环境的通用做法，标为不支持。
class LinuxHost extends PlainHost with _DesktopWindow {
  LinuxHost(super.paths);

  /// GTK 没有 WM_NCHITTEST，标题栏拖动只能由 Dart 发起。
  @override
  bool get titleBarDragInDart => true;

  @override
  bool get autostartSupported => true;
  @override
  bool get shortcutSupported => true;

  String get _configHome {
    final base = Platform.environment['XDG_CONFIG_HOME'];
    if (base != null && base.isNotEmpty) return base;
    return p.join(Platform.environment['HOME'] ?? '', '.config');
  }

  String get _dataHome {
    final base = Platform.environment['XDG_DATA_HOME'];
    if (base != null && base.isNotEmpty) return base;
    return p.join(Platform.environment['HOME'] ?? '', '.local', 'share');
  }

  /// `~/.config/autostart/memonest.desktop`
  String get _autostartPath => p.join(_configHome, 'autostart', 'memonest.desktop');

  String get _execLine => Platform.resolvedExecutable;

  @override
  bool autostartEnabled() {
    final file = File(_autostartPath);
    if (!file.existsSync()) return false;
    try {
      return file.readAsStringSync().contains('Exec=$_execLine');
    } on FileSystemException {
      return false;
    }
  }

  @override
  void setAutostart(bool enabled) {
    final file = File(_autostartPath);
    try {
      if (!enabled) {
        if (file.existsSync()) file.deleteSync();
        return;
      }
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=MemoNest 备忘录\n'
        'Comment=MemoNest 备忘录\n'
        'Exec=$_execLine\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n',
        encoding: utf8,
      );
    } on FileSystemException catch (e) {
      throw HostError('写入自启文件失败：${e.message}');
    }
  }

  /// Linux 没有「桌面快捷方式」的统一做法：GNOME/KDE 用 .desktop，
  /// 写到 `~/.local/share/applications/`，应用菜单里就能搜到。
  @override
  String createDesktopShortcut() {
    final path = p.join(_dataHome, 'applications', 'memonest.desktop');
    try {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '[Desktop Entry]\n'
          'Type=Application\n'
          'Name=MemoNest 备忘录\n'
          'Comment=MemoNest 备忘录\n'
          'Exec=$_execLine\n'
          'Terminal=false\n'
          'Categories=Utility;TextEditor;\n',
          encoding: utf8,
        );
    } on FileSystemException catch (e) {
      throw HostError('写入桌面条目失败：${e.message}');
    }
    return path;
  }
}

// ---------------- Android ----------------

/// Android：没有桌面窗口，自启/快捷方式/剪贴板位图都不适用；
/// 系统验证与密钥保护走 `memonest/hello` 通道的 Android 实现（Keystore）。
class AndroidHost extends PlainHost {
  AndroidHost(super.paths);

  @override
  bool get deviceAuthSupported => true;
  @override
  bool get secretSupported => true;

  @override
  String get authLabel => '指纹 / 面容解锁';

  @override
  String get authShort => '生物识别';

  @override
  Future<bool> deviceAuthAvailable() =>
      _helloChannel('available').then((v) => v == true);

  @override
  Future<bool> deviceAuthVerify({String prompt = '解锁私密笔记库'}) =>
      _helloChannel('authenticate', {'prompt': prompt}).then((v) => v == true);

  @override
  Future<Uint8List> protectSecret(Uint8List plain,
      {String description = 'MemoNest 私密库'}) async {
    final result = await _helloChannel('protect', {
      'data': base64Encode(plain),
      'description': description,
    });
    if (result is! String) throw const HostError('托管凭据失败：原生侧没有返回数据');
    return base64Decode(result);
  }

  @override
  Future<Uint8List> unprotectSecret(Uint8List blob) async {
    final result = await _helloChannel('unprotect', {
      'data': base64Encode(blob),
    });
    if (result is! String) throw const HostError('读取凭据失败：原生侧没有返回数据');
    return base64Decode(result);
  }
}
