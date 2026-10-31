/// 平台宿主：窗口、Shell 集成、剪贴板位图、系统凭据验证的抽象层。
///
/// 这些能力在三个平台上实现方式完全不同：
/// - Windows：window_manager + 注册表/PowerShell + Win32 CF_DIB + DPAPI/Hello
/// - Linux：window_manager（X11/Wayland）+ XDG autostart + 无位图剪贴板
/// - Android：没有桌面窗口、没有自启；图片走系统选择器，验证走生物识别
///
/// 上层只依赖这里暴露的接口，具体实现在 `host_io.dart`。
library;

import 'package:flutter/foundation.dart';

/// 剪贴板里的位图。`pixels` 是自上而下的 BGR/BGRX 行数据。
class ClipboardBitmap {
  final int width;
  final int height;
  final int bitCount;
  final Uint8List pixels;

  ClipboardBitmap(this.width, this.height, this.bitCount, this.pixels);
}

/// Shell 集成失败。文案可以直接显示给用户。
class HostError implements Exception {
  final String message;
  const HostError(this.message);
  @override
  String toString() => message;
}

/// 平台宿主接口。
abstract class Host {
  /// 是否支持「桌面窗口」这一套（自绘标题栏、最小化/最大化、窗口几何）。
  bool get isDesktop;

  /// 是否支持开机自启。
  bool get autostartSupported;

  /// 是否支持创建桌面快捷方式/菜单条目。
  bool get shortcutSupported;

  /// 是否支持从剪贴板直接读位图（Android 用图片选择器，不支持）。
  bool get clipboardImageSupported;

  /// 是否支持系统级生物识别/凭据验证（Windows Hello、Android 生物识别）。
  bool get deviceAuthSupported;

  /// 是否支持用平台密钥库托管库密钥（Windows DPAPI、Android Keystore）。
  bool get secretSupported;

  /// [protectSecret] / [unprotectSecret] 是否已经内置了系统验证。
  ///
  /// Android 的 Keystore 密钥绑定了生物识别，`Cipher.init` 之后必须把
  /// Cipher 交给 `BiometricPrompt` 才能用，所以验证是加解密的一部分。
  /// 这种平台上调用方不要再单独调 [deviceAuthVerify]，否则会连弹两次。
  bool get secretPromptBuiltIn;

  // ---------- 窗口 ----------

  /// 启动时初始化窗口系统。
  Future<void> initWindow();

  /// 把 config 里的窗口偏好落到真实窗口上。
  Future<void> applyWindowPrefs({
    required bool alwaysOnTop,
    required String geometry,
  });

  /// 退出前收尾。
  Future<void> destroyWindow();

  Future<void> setAlwaysOnTop(bool value);
  Future<void> minimize();
  Future<void> toggleMaximize();
  Future<void> closeWindow();
  Future<bool> isMaximized();

  /// 当前窗口尺寸与位置（`WxH+X+Y`）。不支持的平台返回 null。
  Future<String?> currentGeometry();

  /// 订阅窗口事件。返回取消订阅的回调。
  VoidCallback addWindowListener({
    required VoidCallback onMaximize,
    required VoidCallback onUnmaximize,
    required Future<void> Function() onClose,
  });

  // ---------- Shell ----------

  bool autostartEnabled();
  void setAutostart(bool enabled);

  /// 创建桌面快捷方式/菜单条目，返回落地的路径。
  String createDesktopShortcut();

  // ---------- 剪贴板位图 ----------

  bool clipboardHasImage();
  ClipboardBitmap? readClipboardBitmap();

  // ---------- 桌面集成 ----------

  /// 用系统文件管理器打开一个目录。Android 上没有这个概念，返回 false。
  Future<bool> openFolder(String path);

  /// 标题栏拖动是否要由 Dart 侧发起。
  ///
  /// Windows 把拖动交给 `WM_NCHITTEST` 返回 `HTCAPTION`，在 Dart 里再调
  /// `startDragging()` 会冻结渲染线程（之前点顶栏必崩就是这个原因）；
  /// Linux 的 GTK 没有等价的命中测试，只能反过来由 Dart 发起。
  bool get titleBarDragInDart;

  /// 让系统开始拖动窗口（只在 [titleBarDragInDart] 为真时有意义）。
  Future<void> startWindowDrag();

  // ---------- 系统凭据验证 ----------

  /// 这套系统验证在这台机器上叫什么（设置里直接显示给用户看）。
  ///
  /// Windows 是「Windows Hello」，Android 是「指纹解锁」，其它平台通用。
  String get authLabel;

  /// 更短的写法，用在句子中间。
  String get authShort;

  /// 系统层面是否可用（Hello 已录入 / 生物识别已录入）。
  Future<bool> deviceAuthAvailable();

  /// 弹出系统验证。用户取消返回 false，调用失败抛 [HostError]。
  Future<bool> deviceAuthVerify({String prompt});

  /// 用平台密钥库保护一段密钥材料。不支持时抛 [HostError]。
  Future<Uint8List> protectSecret(Uint8List plain, {String description});

  /// 解开 [protectSecret] 的产物。失败抛 [HostError]。
  Future<Uint8List> unprotectSecret(Uint8List blob);
}
