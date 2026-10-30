import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/app_state.dart';
import 'package:memonest/core/paths.dart';
import 'package:memonest/ui/panels/vault_panel.dart';

AppPaths makePaths(String name) =>
    AppPaths(Directory.systemTemp.createTempSync(name));

/// 把原生通道换成假的，模拟「这台机器 Hello 可用 / 不可用」。
void answerHello(bool available) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('memonest/hello'),
          (MethodCall call) async {
    if (call.method == 'available') return available;
    if (call.method == 'authenticate') return true;
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppState> pumpPanel(WidgetTester tester, String name) async {
    final state = AppState(paths: makePaths(name));
    state.initialize();
    await state.createVault('pw-123456');
    // 删掉托管记录，回到「第一次解锁」的状态。
    state.hello.forget();
    state.switchLibrary(LibraryKind.notes);
    state.switchLibrary(LibraryKind.vault);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VaultPanel(state: state, onClose: () {}),
      ),
    ));
    // 让 _probeHello 的异步结果落地。
    await tester.pumpAndSettle();
    return state;
  }

  testWidgets('设备支持时，第一次解锁也显示 Windows Hello 按钮', (tester) async {
    answerHello(true);
    await pumpPanel(tester, 'panel_hello_on');
    expect(find.text('用 Windows Hello 解锁'), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint), findsOneWidget);
  });

  testWidgets('设备不支持时不显示 Hello 按钮', (tester) async {
    answerHello(false);
    await pumpPanel(tester, 'panel_hello_off');
    expect(find.text('用 Windows Hello 解锁'), findsNothing);
    // 主密码通道照旧可用。
    expect(find.text('解锁'), findsOneWidget);
  });

  testWidgets('创建模式下不显示 Hello 按钮', (tester) async {
    answerHello(true);
    final state = AppState(paths: makePaths('panel_hello_create'));
    state.initialize();
    state.vaultPanelOpen = true;
    state.vaultPanelMode = VaultPanelMode.create;
    state.refresh();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: VaultPanel(state: state, onClose: () {})),
    ));
    await tester.pumpAndSettle();
    expect(find.text('用 Windows Hello 解锁'), findsNothing);
  });
}
