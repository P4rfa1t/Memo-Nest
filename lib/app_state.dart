/// 应用状态：持有两个库（普通 / 私密）、当前便签、搜索、预览等，
/// 并负责自动保存、锁定、备份调度。
///
/// 这一层不碰任何 Widget，UI 通过 `ChangeNotifier` 订阅，
/// 逻辑可以脱离 Flutter 单独测试。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/backup.dart';
import '../core/github_backup.dart';
import '../core/models.dart';
import '../core/note_store.dart';
import '../core/onedrive.dart';
import '../core/paths.dart';
import '../core/store_api.dart';
import '../core/hello.dart';
import '../core/vault_store.dart';

enum LibraryKind { notes, vault }

/// 私密库面板的三种形态。
enum VaultPanelMode { none, create, unlock, password }

class AppState extends ChangeNotifier {
  final AppPaths paths;
  late final Config config;
  late NoteStore plainStore;
  Vault? vault;
  VaultStore? vaultStore;

  LibraryKind library = LibraryKind.notes;
  Note? current;

  String searchQuery = '';
  String? activeTag;
  bool previewMode = false;
  bool vaultPanelOpen = false;
  VaultPanelMode vaultPanelMode = VaultPanelMode.none;
  String statusMessage = '';

  /// 备份进行中：按钮据此显示「备份中…」并挡住重复点击。
  bool backupRunning = false;

  /// 窗口是否最大化：自绘标题栏靠它决定中间那颗按钮画「方块」还是「还原」。
  bool maximized = false;

  Timer? _autosave;
  Timer? _backupTimer;
  bool _dirty = false;
  bool _loading = false;
  bool _dirtySinceBackup = false;

  AppState({AppPaths? paths}) : paths = paths ?? AppPaths() {
    config = Config(this.paths.configPath);
    this.paths.ensureDirs();
    plainStore = NoteStore.fromPaths(this.paths);
    _startBackupTimer();
  }

  // ---------- 当前库 ----------
  /// Windows Hello 解锁服务（DPAPI 托管库密钥 + 系统验证对话框）。
  HelloUnlock get hello => HelloUnlock(paths, config);

  bool get isVault => library == LibraryKind.vault;
  NotesStore? get store {
    if (isVault) return vaultStore;
    return plainStore;
  }

  bool get vaultLocked => vault == null || !vault!.unlocked;

  List<Note> get visibleNotes {
    final s = store;
    if (s == null) return const [];
    return s.filter(query: searchQuery, tag: activeTag);
  }

  Map<String, int> get tags {
    final s = store;
    return s?.allTags() ?? const {};
  }

  String get libraryLabel => isVault ? '私密' : '便签';

  // ---------- 初始化 ----------
  Future<void> initialize() async {
    if (File(paths.vaultMetaPath).existsSync()) {
      vault = Vault(paths.vaultDir);
    }
    if (plainStore.allNotes().isEmpty) {
      final welcome =
          plainStore.create(title: '欢迎使用 MemoNest', content: welcomeText);
      current = welcome;
      plainStore.save(welcome);
    } else {
      current = plainStore.allNotes().first;
    }
    notifyListeners();
  }

  // ---------- 便签操作 ----------
  void selectNote(Note note) {
    saveCurrent();
    current = note;
    _dirty = false;
    notifyListeners();
  }

  Note? newNote() {
    final s = store;
    if (s == null) return null;
    saveCurrent();
    final note = s.create(title: '', content: '');
    current = note;
    _dirty = false;
    notifyListeners();
    return note;
  }

  void markDirty() {
    _dirty = true;
    _dirtySinceBackup = true;
    _autosave?.cancel();
    _autosave = Timer(const Duration(milliseconds: 600), saveCurrent);
  }

  void saveCurrent({bool force = false}) {
    final s = store;
    final note = current;
    if (s == null || note == null) return;
    if (!_dirty && !force) return;
    if (_loading) return;
    try {
      s.save(note);
      _dirty = false;
      statusMessage = '已保存';
    } on Exception catch (e) {
      statusMessage = '保存失败：$e';
    }
    notifyListeners();
  }

  bool deleteCurrent() {
    final s = store;
    final note = current;
    if (s == null || note == null) return false;
    s.delete(note.id);
    current = s.allNotes().isEmpty ? null : s.allNotes().first;
    _dirty = false;
    notifyListeners();
    return true;
  }

  void togglePin() {
    final note = current;
    if (note == null) return;
    note.pinned = !note.pinned;
    saveCurrent(force: true);
  }

  void updateTitle(String value) {
    final note = current;
    if (note == null) return;
    note.title = value;
    markDirty();
    notifyListeners();
  }

  void updateTags(String value) {
    final note = current;
    if (note == null) return;
    note.tags = value
        .split(RegExp(r'[,，\s]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    markDirty();
    notifyListeners();
  }

  void updateContent(String value) {
    final note = current;
    if (note == null) return;
    note.content = value;
    markDirty();
    notifyListeners();
  }

  // ---------- 搜索 ----------
  void setQuery(String value) {
    searchQuery = value;
    notifyListeners();
  }

  void setTag(String? tag) {
    activeTag = tag;
    notifyListeners();
  }

  // ---------- 库切换 ----------
  void switchLibrary(LibraryKind kind) {
    if (kind == library) return;
    saveCurrent();
    library = kind;
    if (kind == LibraryKind.vault && vaultLocked) {
      vaultPanelOpen = true;
      vaultPanelMode = vault != null && vault!.exists()
          ? VaultPanelMode.unlock
          : VaultPanelMode.create;
      current = null;
    } else {
      final s = store;
      current = s == null || s.allNotes().isEmpty ? null : s.allNotes().first;
    }
    searchQuery = '';
    activeTag = null;
    previewMode = false;
    notifyListeners();
  }

  // ---------- 私密库 ----------
  Future<void> createVault(String password) async {
    vault ??= Vault(paths.vaultDir);
    vault!.create(password);
    vaultStore = VaultStore(vault!);
    library = LibraryKind.vault;
    vaultPanelOpen = false;
    vaultPanelMode = VaultPanelMode.none;
    final s = vaultStore!;
    current = s.allNotes().isEmpty
        ? s.create(title: '私密便签', content: '')
        : s.allNotes().first;
    _rememberHelloKey();
    notifyListeners();
  }

  /// 库已解锁就把库密钥托给系统凭据保护，下次可以直接 Hello 解锁。
  ///
  /// 失败不影响主流程（比如 DPAPI 被策略禁用），只是下次还得输密码。
  void _rememberHelloKey() {
    final key = vault?.key;
    if (key == null) return;
    final service = hello;
    if (!service.enabled) return;
    try {
      service.remember(key);
    } on HelloError {
      // 忽略：托管失败只影响便利性
    } on FileSystemException {
      // 同上
    }
  }

  Future<void> unlockVault(String password) async {
    vault ??= Vault(paths.vaultDir);
    vault!.unlock(password);
    vaultStore = VaultStore(vault!);
    library = LibraryKind.vault;
    vaultPanelOpen = false;
    vaultPanelMode = VaultPanelMode.none;
    final s = vaultStore!;
    current = s.allNotes().isEmpty ? null : s.allNotes().first;
    _rememberHelloKey();
    notifyListeners();
  }

  /// 用 Windows Hello 验证并解锁。用户取消会抛 [HelloError]('已取消')。
  Future<void> unlockVaultWithHello() async {
    final service = hello;
    final key = await service.retrieve();
    vault ??= Vault(paths.vaultDir);
    vault!.unlockWithKey(key);
    vaultStore = VaultStore(vault!);
    library = LibraryKind.vault;
    vaultPanelOpen = false;
    vaultPanelMode = VaultPanelMode.none;
    final s = vaultStore!;
    current = s.allNotes().isEmpty ? null : s.allNotes().first;
    notifyListeners();
  }

  void lockVault() {
    if (vault == null) return;
    saveCurrent(force: true);
    vault!.lock();
    vaultStore = null;
    if (library == LibraryKind.vault) {
      library = LibraryKind.notes;
      current =
          plainStore.allNotes().isEmpty ? null : plainStore.allNotes().first;
    }
    notifyListeners();
  }

  void changeVaultPassword(String oldPassword, String newPassword) {
    if (vault == null) throw VaultError('找不到加密库');
    vault!.changePassword(oldPassword, newPassword);
    notifyListeners();
  }

  /// 忘记主密码时彻底清空加密库。不可恢复，UI 侧必须先确认。
  void resetVault() {
    saveCurrent(force: true);
    // 库密钥要换新，旧托管记录必然对不上，直接删掉免得误报。
    hello.forget();
    vault?.reset();
    vault = null;
    vaultStore = null;
    if (library == LibraryKind.vault) {
      library = LibraryKind.notes;
      current =
          plainStore.allNotes().isEmpty ? null : plainStore.allNotes().first;
    }
    vaultPanelOpen = false;
    vaultPanelMode = VaultPanelMode.none;
    statusMessage = '私密库已清空';
    notifyListeners();
  }

  /// 在普通库与私密库之间移动当前便签。
  ///
  /// 私密库还没解锁时先把面板打开，让用户解锁后再移动——
  /// 明文写进加密库这种降级绝不做。
  void moveCurrentBetweenLibraries() {
    final note = current;
    if (note == null) return;
    if (isVault) {
      if (vaultStore == null) {
        statusMessage = '私密库已锁定';
        notifyListeners();
        return;
      }
      final moved = Note(
        id: newId(),
        title: note.title,
        tags: List<String>.from(note.tags),
        created: note.created,
        updated: isoNow(),
        pinned: note.pinned,
        content: note.content,
      );
      plainStore.save(moved);
      vaultStore!.delete(note.id);
      current = moved;
      statusMessage = '已移回普通便签';
    } else {
      if (vaultStore == null) {
        vaultPanelOpen = true;
        vaultPanelMode = vault != null && vault!.exists()
            ? VaultPanelMode.unlock
            : VaultPanelMode.create;
        statusMessage = '先解锁私密库';
        notifyListeners();
        return;
      }
      final moved = Note(
        id: newId(),
        title: note.title,
        tags: List<String>.from(note.tags),
        created: note.created,
        updated: isoNow(),
        pinned: note.pinned,
        content: note.content,
      );
      vaultStore!.save(moved);
      plainStore.delete(note.id);
      current = moved;
      statusMessage = '已移到私密笔记库';
    }
    notifyListeners();
  }

  // ---------- 回收站 ----------
  List<TrashEntry> trashEntries() {
    final entries = <TrashEntry>[];
    entries.addAll(plainStore.listTrash());
    if (vaultStore != null) entries.addAll(vaultStore!.listTrash());
    entries.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return entries;
  }

  void restoreTrash(TrashEntry entry) {
    if (entry.source == 'vault') {
      vaultStore?.restoreTrash(entry);
    } else {
      plainStore.restoreTrash(entry);
    }
    notifyListeners();
  }

  void deleteTrash(TrashEntry entry) {
    try {
      File(entry.path).deleteSync();
      final meta =
          File(entry.path.replaceAll(RegExp(r'\.(md|mdenc)$'), '.json'));
      if (meta.existsSync()) meta.deleteSync();
    } on FileSystemException {
      // 忽略
    }
    notifyListeners();
  }

  // ---------- 备份 ----------
  BackupService get backup => BackupService(paths, config);
  GitHubService get github => GitHubService(paths, config);
  OneDriveService get oneDrive => OneDriveService(paths, config);

  /// OneDrive 当前的同步模式：`folder`（复制到本地 OneDrive 目录）或
  /// `graph`（登录 Microsoft 账号直接上传）。默认 folder。
  String get oneDriveMode {
    final raw = '${config.get('onedrive.mode', 'folder') ?? 'folder'}'.trim();
    return raw == 'graph' ? 'graph' : 'folder';
  }

  void setOneDriveMode(String mode) {
    config.set('onedrive.mode', mode == 'graph' ? 'graph' : 'folder');
    config.save();
    notifyListeners();
  }

  /// 依次跑本地打包 → OneDrive → GitHub，把每一步的结果写进状态栏。
  ///
  /// 与 Python 版 `run_backup` 一样：一步失败不影响后面的步骤，
  /// 失败原因逐条汇报，而不是整批放弃。
  ///
  /// OneDrive 按模式分派：folder 模式直接复制；graph 模式登录后才上传，
  /// 未登录时给一句提示而不是抛错——用户可能只是忘了登录。
  Future<void> runBackup({String label = ''}) async {
    if (backupRunning) return;
    backupRunning = true;
    statusMessage = '正在备份…';
    notifyListeners();
    _dirtySinceBackup = false;
    final steps = <String>[];
    try {
      await _runBackupSteps(steps, label: label);
    } finally {
      backupRunning = false;
    }
    statusMessage = steps.isEmpty ? '没有可备份的内容' : steps.join('；');
    notifyListeners();
  }

  /// 备份的实际步骤：本地快照 → OneDrive → GitHub。
  ///
  /// 抽出来是为了让 [runBackup] 用 try/finally 复位 `backupRunning`——
  /// 任何一步抛出未捕获异常时都不会把备份按钮永久锁死。
  Future<void> _runBackupSteps(List<String> steps,
      {required String label}) async {
    File? snapshot;
    try {
      snapshot = backup.createSnapshot(label: label);
      steps.add('本地 ${p.basename(snapshot.path)}');
      backup.prune();
    } on BackupError catch (e) {
      steps.add('本地失败：${e.message}');
    } on FileSystemException catch (e) {
      steps.add('本地失败：${e.message}');
    }

    if (config.get('onedrive.enabled', false) == true) {
      if (oneDriveMode == 'graph') {
        final service = oneDrive;
        if (service.clientId.isEmpty) {
          steps.add('OneDrive 失败：请先填写 Azure 应用 ID');
        } else if (!service.isLoggedIn) {
          steps.add('OneDrive 失败：尚未登录 Microsoft 账号');
        } else {
          try {
            steps.add('OneDrive ${await service.sync(snapshot: snapshot)}');
          } on GraphError catch (e) {
            steps.add('OneDrive 失败：${e.message}');
          } on FileSystemException catch (e) {
            steps.add('OneDrive 失败：${e.message}');
          }
        }
      } else {
        try {
          final detail = backup.mirrorToFolder();
          if (detail != null) steps.add('OneDrive $detail');
        } on BackupError catch (e) {
          steps.add('OneDrive 失败：${e.message}');
        }
      }
    }

    if (config.get('github.enabled', false) == true) {
      try {
        steps.add('GitHub ${await github.push()}');
      } on GitHubError catch (e) {
        steps.add('GitHub 失败：${e.message}');
      }
    }
  }

  /// 上次备份之后有没有改动过（决定退出时要不要备份）。
  bool get hasUnsavedBackup => _dirtySinceBackup;

  void _startBackupTimer() {
    _backupTimer?.cancel();
    final minutes =
        (config.get('general.auto_backup_minutes', 0) as num).toInt();
    if (minutes <= 0) return;
    _backupTimer = Timer.periodic(
      Duration(minutes: minutes),
      (_) => runBackup(label: 'auto').catchError((Object e) {
        statusMessage = '自动备份失败：$e';
        notifyListeners();
      }),
    );
  }

  void setAutoBackupMinutes(int minutes) {
    config.set('general.auto_backup_minutes', minutes);
    config.save();
    _startBackupTimer();
    notifyListeners();
  }

  /// UI 侧改完公开字段后调它，把变更广播出去。
  void refresh() => notifyListeners();

  void setMaximized(bool value) {
    if (maximized == value) return;
    maximized = value;
    notifyListeners();
  }

  // ---------- 窗口拖动 ----------
  // 自绘标题栏后没有 NCHITTEST 的系统拖动区。用 window_manager 的
  // `startDragging` 的话，Windows 自己接管了鼠标循环，松手前不会再有任何
  // 鼠标事件回到 Dart 侧——分不清「单击」和「拖完松手」，于是点标题栏会误
  // 触发双击最大化。这里改成自己跟踪：按下时记住起点，移动超过阈值才判定
  // 为拖动，松手后 300ms 内落下第二次单击才算双击。

  double? _titleBarPressX;
  double? _titleBarPressY;

  void noteTitleBarPress(double x, double y) {
    _titleBarPressX = x;
    _titleBarPressY = y;
  }

  (double, double)? get titleBarPressOrigin {
    final x = _titleBarPressX;
    final y = _titleBarPressY;
    return (x == null || y == null) ? null : (x, y);
  }

  void clearTitleBarPress() {
    _titleBarPressX = null;
    _titleBarPressY = null;
  }

  // ---------- 生命周期 ----------
  void setLoading(bool value) {
    _loading = value;
  }

  void disposeState() {
    _autosave?.cancel();
    _backupTimer?.cancel();
    saveCurrent(force: true);
    super.dispose();
  }
}

const String welcomeText = '''\
这是一张可以一直贴在桌面上的便签。标题写在上方，正文直接写 Markdown。

## 快速上手

- 顶部下拉框切换便签，按 `+` 新建，点 📌 置顶当前便签
- 点 🗑 删除当前便签，删掉的便签可在「⋯ → 回收站」恢复
- 内容会自动保存，不需要手动保存
- 点「预览」查看渲染效果，再点一次回到编辑
- 点 🔍 搜索便签，`Esc` 收起；`Ctrl+F` 也能打开

## 支持的 Markdown

**加粗**、*斜体*、~~删除线~~、`行内代码`、[链接](https://example.com)

```python
print("代码块也支持")
```

- 无序列表
- 任务列表
- [x] 已完成的项

> 引用会显示成左侧带竖线的段落。

| 名称 | 数量 |
| --- | --- |
| 苹果 | 3 |

---

右键正文可以把剪贴板里的图片粘贴进来。
''';
