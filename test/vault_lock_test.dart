import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/app_state.dart';
import 'package:memonest/core/hello.dart';
import 'package:memonest/core/paths.dart';
import 'package:path/path.dart' as p;

AppPaths makePaths(String name) {
  final root = Directory.systemTemp.createTempSync(name);
  return AppPaths(root);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('私密库上锁行为', () {
    test('切回普通便签后私密库立即上锁，store 也清掉', () async {
      final state = AppState(paths: makePaths('vault_lock_switch'));
      state.initialize();
      await state.createVault('pw-123456');
      expect(state.isVault, isTrue);
      expect(state.vaultStore, isNotNull);
      expect(state.vaultLocked, isFalse);

      state.switchLibrary(LibraryKind.notes);

      expect(state.library, LibraryKind.notes);
      // 库对象还在（磁盘上有），但必须是锁着的。
      expect(state.vault, isNotNull);
      expect(state.vaultLocked, isTrue);
      expect(state.vaultStore, isNull);
    });

    test('锁上之后重新点私密要再解锁，且内容还在', () async {
      final state = AppState(paths: makePaths('vault_lock_reenter'));
      state.initialize();
      await state.createVault('pw-abcdef');
      state.updateTitle('机密标题');
      state.saveCurrent(force: true);
      state.switchLibrary(LibraryKind.notes);
      expect(state.vaultLocked, isTrue);

      state.switchLibrary(LibraryKind.vault);
      // 锁着进私密：弹解锁面板，不直接给内容。
      expect(state.vaultPanelOpen, isTrue);
      expect(state.vaultPanelMode, VaultPanelMode.unlock);
      expect(state.vaultStore, isNull);

      await state.unlockVault('pw-abcdef');
      expect(state.vaultLocked, isFalse);
      expect(state.vaultStore!.allNotes().single.title, '机密标题');
    });

    test('切到私密之前改的东西会被强制落盘，不丢', () async {
      final state = AppState(paths: makePaths('vault_lock_flush'));
      state.initialize();
      await state.createVault('pw-flush');
      state.updateContent('离开前刚打的一行');
      expect(state.current!.content, '离开前刚打的一行');

      state.switchLibrary(LibraryKind.notes);

      // 解锁回来应该还在。
      await state.unlockVault('pw-flush');
      expect(state.vaultStore!.allNotes().single.content, '离开前刚打的一行');
    });
  });

  group('Windows Hello 按钮不被自身凭据卡住', () {
    test('没有托管记录时也能判断按钮该不该显示', () async {
      final paths = makePaths('vault_hello_gate');
      final state = AppState(paths: paths);
      state.initialize();
      await state.createVault('pw-hello');

      final service = state.hello;
      // 创建库时会顺手托管，此时已经有记录。
      expect(File(p.join(paths.vaultDir, 'hello.bin')).existsSync(), isTrue);
      expect(service.available, isTrue);

      // 把记录删掉，模拟「第一次解锁前还没托管」：
      // 按钮的显示不能依赖这个文件。
      service.forget();
      expect(File(p.join(paths.vaultDir, 'hello.bin')).existsSync(), isFalse);
      expect(service.available, isFalse);

      // retrieve 给出的是可以照做的指引，而不是崩掉。
      await expectLater(
        service.retrieve(),
        throwsA(isA<HelloError>().having(
          (e) => e.message,
          'message',
          contains('请先用主密码解锁一次'),
        )),
      );
    });
  });
}
