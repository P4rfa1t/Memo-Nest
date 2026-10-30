/// 应用入口：窗口初始化、状态注入、全局快捷键。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'core/paths.dart';
import 'platform/host_io.dart';
import 'ui/main_window.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android 没有「可执行文件旁边」这个概念，应用私有目录只能通过
  // path_provider 拿；必须在 AppState 构造之前定好根目录。
  if (Platform.isAndroid) {
    final dir = await getApplicationSupportDirectory();
    setAppRootOverride(dir);
  }

  final host = createHost(AppPaths());
  await host.initWindow();

  final state = AppState(host: host);
  await state.initialize();
  await _applyWindowPrefs(state);

  runApp(MemoNestApp(state: state));
}

/// 把 config.json 里的窗口相关设置落到真实窗口上。
///
/// `general.window_geometry` 沿用 Python 版的 Tk 几何串 `WxH+X+Y`，
/// 三个版本互相切换时窗口位置与大小能延续。
Future<void> _applyWindowPrefs(AppState state) async {
  if (!state.host.isDesktop) return;
  try {
    final alwaysOnTop =
        state.config.get('general.always_on_top', false) == true;
    final geometry = state.config.get('general.window_geometry');
    await state.host.applyWindowPrefs(
      alwaysOnTop: alwaysOnTop,
      geometry: geometry is String ? geometry : '',
    );
  } on Exception catch (e) {
    debugPrint('应用窗口设置失败：$e');
  }
}

class MemoNestApp extends StatefulWidget {
  final AppState state;

  const MemoNestApp({super.key, required this.state});

  @override
  State<MemoNestApp> createState() => _MemoNestAppState();
}

class _MemoNestAppState extends State<MemoNestApp> {
  VoidCallback? _unsubscribe;

  @override
  void initState() {
    super.initState();
    _unsubscribe = widget.state.host.addWindowListener(
      onMaximize: () => widget.state.setMaximized(true),
      onUnmaximize: () => widget.state.setMaximized(false),
      onClose: _onClose,
    );
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  Future<void> _onClose() async {
    // 先落盘、再记住窗口几何，最后才真正退出。
    try {
      widget.state.saveCurrent(force: true);
      final geometry = await widget.state.host.currentGeometry();
      if (geometry != null) {
        widget.state.config.set('general.window_geometry', geometry);
        widget.state.config.save();
      }
    } on Exception catch (e) {
      debugPrint('退出前保存失败：$e');
    }
    widget.state.disposeState();
    await widget.state.host.destroyWindow();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MemoNest 备忘录',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: MainWindow(state: widget.state),
    );
  }
}
