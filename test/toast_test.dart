import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/app_state.dart';
import 'package:memonest/core/paths.dart';
import 'package:memonest/core/toast.dart';
import 'package:memonest/platform/host.dart';
import 'package:memonest/platform/host_io.dart';

AppPaths makePaths(String name) =>
    AppPaths(Directory.systemTemp.createTempSync(name));

/// 假宿主：能托管密钥，但记录下「单独弹了几次验证」。
///
/// 用它区分两种平台：
/// - `promptBuiltIn: false`（Windows DPAPI）→ 先弹验证，再解密；
/// - `promptBuiltIn: true`（Android Keystore）→ 验证在解密内部，不再单独弹。
class FakeHost extends PlainHost {
  final bool promptBuiltIn;
  int verifyCalls = 0;
  int protectCalls = 0;
  int unprotectCalls = 0;

  /// 内存里的「密钥库」，不碰真实 DPAPI/Keystore。
  final Map<String, Uint8List> _vault = <String, Uint8List>{};
  int _seq = 0;

  FakeHost(super.paths, {required this.promptBuiltIn});

  @override
  bool get deviceAuthSupported => true;
  @override
  bool get secretSupported => true;
  @override
  bool get secretPromptBuiltIn => promptBuiltIn;

  @override
  Future<bool> deviceAuthAvailable() async => true;

  @override
  Future<bool> deviceAuthVerify({String prompt = '解锁私密笔记库'}) async {
    verifyCalls++;
    return true;
  }

  @override
  Future<Uint8List> protectSecret(Uint8List plain,
      {String description = ''}) async {
    protectCalls++;
    final id = 'blob-${++_seq}';
    _vault[id] = Uint8List.fromList(plain);
    // 原样包一层，能还原就行——这里测的是调用次序，不是加密。
    return Uint8List.fromList(utf8.encode(id));
  }

  @override
  Future<Uint8List> unprotectSecret(Uint8List blob) async {
    unprotectCalls++;
    final id = utf8.decode(blob);
    final plain = _vault[id];
    if (plain == null) throw const HostError('系统凭据已失效，请用主密码解锁');
    return Uint8List.fromList(plain);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('右下角浮层', () {
    test('弹出后进队列，到期自动消失', () async {
      final state = AppState(paths: makePaths('toast_basic'));
      addTearDown(state.disposeState);
      state.initialize();

      state.showToast('已备份到 OneDrive', kind: ToastKind.success);
      expect(state.toasts, hasLength(1));
      expect(state.toasts.single.text, '已备份到 OneDrive');
      expect(state.toasts.single.kind, ToastKind.success);

      // 不等真实 4 秒，直接调内部的到期回调。
      state.dismissToast(state.toasts.single.id);
      expect(state.toasts, isEmpty);
    });

    test('同一条文字连着来只留一条，不叠罗汉', () async {
      final state = AppState(paths: makePaths('toast_dedupe'));
      addTearDown(state.disposeState);
      state.initialize();

      state.showToast('没有可备份的内容');
      state.showToast('没有可备份的内容');
      state.showToast('没有可备份的内容');

      expect(state.toasts, hasLength(1));
      expect(state.toasts.single.text, '没有可备份的内容');
    });

    test('不同消息最多同时显示 3 条，挤掉最老的', () async {
      final state = AppState(paths: makePaths('toast_cap'));
      addTearDown(state.disposeState);
      state.initialize();

      for (var i = 1; i <= 5; i++) {
        state.showToast('第 $i 条');
      }

      expect(state.toasts, hasLength(3));
      expect(state.toasts.map((t) => t.text).toList(),
          ['第 3 条', '第 4 条', '第 5 条']);
    });

    test('空白消息直接丢掉，不会留个空卡片', () async {
      final state = AppState(paths: makePaths('toast_blank'));
      addTearDown(state.disposeState);
      state.initialize();

      state.showToast('   ');
      state.showToast('');
      expect(state.toasts, isEmpty);
    });

    test('备份结果按行分隔，带「失败」就标红', () async {
      final state = AppState(paths: makePaths('toast_backup'));
      addTearDown(state.disposeState);
      state.initialize();

      // 没有远端配置时备份只做本地快照，结果是一段可读文字。
      await state.runBackup();
      expect(state.toasts, isNotEmpty);
      final toast = state.toasts.last;
      expect(toast.text.contains('；'), isFalse,
          reason: '多步结果应该换行，不该用分号拼成一行');
      expect(toast.kind, isNot(ToastKind.error));
    });
  });

  group('系统凭据：验证该由谁弹', () {
    test('Android 那种「验证内置在解密里」的平台，不再单独弹验证', () async {
      final paths = makePaths('hello_builtin');
      final host = FakeHost(paths, promptBuiltIn: true);
      final state = AppState(paths: paths, host: host);
      addTearDown(state.disposeState);
      state.initialize();
      await state.createVault('pw-123456');

      // 创建时会顺手托管一次。
      expect(host.protectCalls, greaterThan(0));
      expect(File(paths.helloPath).existsSync(), isTrue);

      host.verifyCalls = 0;
      host.unprotectCalls = 0;
      final key = await state.hello.retrieve();

      expect(key, isNotEmpty);
      expect(host.unprotectCalls, 1);
      expect(host.verifyCalls, 0,
          reason: 'Android 上解密自带验证框，再弹一次会连出两个对话框');
    });

    test('Windows 那种「DPAPI 不带验证」的平台，先弹验证再解密', () async {
      final paths = makePaths('hello_dpapi');
      final host = FakeHost(paths, promptBuiltIn: false);
      final state = AppState(paths: paths, host: host);
      addTearDown(state.disposeState);
      state.initialize();
      await state.createVault('pw-123456');

      host.verifyCalls = 0;
      host.unprotectCalls = 0;
      final key = await state.hello.retrieve();

      expect(key, isNotEmpty);
      expect(host.verifyCalls, 1);
      expect(host.unprotectCalls, 1);
    });

    test('托管失败会说出来，不再静默吞掉', () async {
      final paths = makePaths('hello_visible_failure');
      final host = _BrokenHost(paths);
      final state = AppState(paths: paths, host: host);
      addTearDown(state.disposeState);
      state.initialize();

      await state.createVault('pw-123456');

      // 之前这里什么都不显示，用户只会看到「明明解锁过了还说没凭据」。
      final messages = state.toasts.map((t) => t.text).join('\n');
      expect(messages, contains('系统凭据托管失败'));
      expect(state.toasts.any((t) => t.kind == ToastKind.error), isTrue);
    });
  });
}

/// 托管一定失败的宿主，用来验证失败会浮出来。
class _BrokenHost extends FakeHost {
  _BrokenHost(super.paths) : super(promptBuiltIn: true);

  @override
  Future<Uint8List> protectSecret(Uint8List plain,
      {String description = ''}) async {
    throw const HostError('这台设备还没有录入指纹或面容');
  }
}
