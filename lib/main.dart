/// 应用入口：窗口初始化、状态注入、全局快捷键。
library;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'ui/main_window.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(456, 679),
    minimumSize: Size(380, 420),
    center: true,
    backgroundColor: Palette.bg,
    titleBarStyle: TitleBarStyle.hidden,
    title: 'MemoNest 备忘录',
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  final state = AppState();
  await state.initialize();
  await _applyWindowPrefs(state);

  runApp(MemoNestApp(state: state));
}

/// 把 config.json 里的窗口相关设置落到真实窗口上。
///
/// `general.window_geometry` 沿用 Python 版的 Tk 几何串 `WxH+X+Y`，
/// 两个版本互相切换时窗口位置与大小能延续。
Future<void> _applyWindowPrefs(AppState state) async {
  try {
    final alwaysOnTop =
        state.config.get('general.always_on_top', false) == true;
    await windowManager.setAlwaysOnTop(alwaysOnTop);

    final geometry = state.config.get('general.window_geometry');
    if (geometry is String) {
      final match =
          RegExp(r'^(\d+)x(\d+)([+-]\d+)([+-]\d+)?$').firstMatch(geometry);
      if (match != null) {
        final w = int.tryParse(match.group(1) ?? '');
        final h = int.tryParse(match.group(2) ?? '');
        final x = int.tryParse(match.group(3) ?? '');
        final y = int.tryParse(match.group(4) ?? '');
        if (w != null && h != null && w >= 380 && h >= 420) {
          await windowManager.setSize(Size(w.toDouble(), h.toDouble()));
          if (x != null && y != null) {
            await windowManager.setPosition(Offset(x.toDouble(), y.toDouble()));
          }
        }
      }
    }
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

class _MemoNestAppState extends State<MemoNestApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // 先落盘、再记住窗口几何，最后才真正退出。
    try {
      widget.state.saveCurrent(force: true);
      // 最大化状态下 getSize 返回的是最大化后的尺寸，记下来会让下次启动
      // 打开成一个「比屏幕还大」的普通窗口，所以还原一次再取。
      final maximized = await windowManager.isMaximized();
      if (maximized) await windowManager.unmaximize();
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      widget.state.config.set(
        'general.window_geometry',
        '${size.width.round()}x${size.height.round()}'
            '${pos.dx >= 0 ? '+' : ''}${pos.dx.round()}'
            '${pos.dy >= 0 ? '+' : ''}${pos.dy.round()}',
      );
      widget.state.config.save();
    } on Exception catch (e) {
      debugPrint('退出前保存失败：$e');
    }
    widget.state.disposeState();
    await windowManager.destroy();
  }

  @override
  void onWindowMaximize() => widget.state.setMaximized(true);

  @override
  void onWindowUnmaximize() => widget.state.setMaximized(false);

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
