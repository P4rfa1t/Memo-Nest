/// 主窗口：顶部品牌行 / 便签选择行 / 搜索行 / 正文 / 状态栏。
///
/// 面板（设置、回收站、私密库、⋯菜单）都用 Overlay 卡片叠在正文之上，
/// 不做独立窗口——和 Tk 版「所有面板内嵌主窗口」保持一致。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app_state.dart';
import '../core/models.dart';
import '../core/note_store.dart';
import 'editor_area.dart';
import 'markdown_view.dart';
import 'panels/menu_overlay.dart';
import 'panels/settings_panel.dart';
import 'panels/trash_panel.dart';
import 'panels/vault_panel.dart';
import 'theme.dart';
import 'widgets/strip_button.dart';

class MainWindow extends StatefulWidget {
  final AppState state;

  /// 自绘标题栏高度，`main.dart` 的 `_applyWindowPrefs` 也要用。
  static const double titleBarHeight = 34;

  /// 移动端没有窗口按钮，标题栏只留品牌标识，压到 26px。
  static const double mobileTitleBarHeight = 26;

  /// 窗口圆角半径，`main.dart` 用同一个值裁 DWM 区域。
  static const double windowRadius = 10;

  const MainWindow({super.key, required this.state});

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _searchOpen = false;
  bool _settingsOpen = false;
  bool _trashOpen = false;
  bool _menuOpen = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_onState);
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      _searchFocus.requestFocus();
    } else {
      _searchController.clear();
      state.setQuery('');
    }
  }

  void _closeOverlays() {
    setState(() {
      _settingsOpen = false;
      _trashOpen = false;
      _menuOpen = false;
    });
  }

  bool get _anyOverlay =>
      _settingsOpen || _trashOpen || _menuOpen || state.vaultPanelOpen;

  @override
  Widget build(BuildContext context) {
    // 无边框窗口在 Windows 上默认是直角，用剪裁让四个角跟着圆角走，
    // 否则窗口投影会在四角露出一圈方形毛边。Android 上窗口铺满屏幕，
    // 剪圆角反而会在四角露出透明黑边，所以只在桌面做。
    final shell = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _toggleSearch,
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
            state.previewMode = !state.previewMode;
            state.refresh();
          },
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              state.newNote(),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            state.saveCurrent(force: true);
          },
          const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
            if (!_anyOverlay) _confirmDelete();
          },
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
            if (state.isVault) state.lockVault();
          },
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () {
            setState(() => _settingsOpen = true);
          },
          const SingleActivator(LogicalKeyboardKey.f5): () => state.runBackup(),
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_anyOverlay) {
              _closeOverlays();
              state.vaultPanelOpen = false;
              state.refresh();
            } else if (_searchOpen) {
              _toggleSearch();
            }
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Palette.bg,
            body: Stack(
              children: [
                SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTitleBar(),
                      _buildHeader(),
                      _buildSelector(),
                      if (_searchOpen) _buildSearchRow(),
                      Expanded(child: _buildBody()),
                      _buildStatusBar(),
                    ],
                  ),
                ),
                if (state.vaultPanelOpen)
                  // 面板铺满整个窗口，遮住标题栏——自绘标题栏之后窗口只剩
                  // 一圈系统边框，最大化/还原在别处也能做，不必和面板抢位置。
                  Positioned.fill(
                    child: SafeArea(
                      child: VaultPanel(
                        state: state,
                        onClose: () {
                          state.vaultPanelOpen = false;
                          state.vaultPanelMode = VaultPanelMode.none;
                          state.refresh();
                        },
                      ),
                    ),
                  ),
                if (_settingsOpen)
                  Positioned.fill(
                    child: SafeArea(
                      child: SettingsPanel(
                        state: state,
                        onClose: () => setState(() => _settingsOpen = false),
                      ),
                    ),
                  ),
                if (_trashOpen)
                  Positioned.fill(
                    child: SafeArea(
                      child: TrashPanel(
                        state: state,
                        onClose: () => setState(() => _trashOpen = false),
                      ),
                    ),
                  ),
                if (_menuOpen)
                  Positioned.fill(
                    child: MenuOverlay(
                      state: state,
                      onClose: () => setState(() => _menuOpen = false),
                      onOpenSettings: () => setState(() {
                        _menuOpen = false;
                        _settingsOpen = true;
                      }),
                      onOpenTrash: () => setState(() {
                        _menuOpen = false;
                        _trashOpen = true;
                      }),
                      onImport: _importNotes,
                      onExport: _exportNote,
                      onOpenDataDir: _openDataDir,
                      onShowHelp: _showHelp,
                      onShowAbout: _showAbout,
                      onQuit: _quit,
                      onDelete: _confirmDelete,
                    ),
                  ),
              ],
            ),
          ),
        ),
    );

    if (!state.host.isDesktop) return shell;
    return ClipRRect(
      borderRadius: BorderRadius.circular(MainWindow.windowRadius),
      child: shell,
    );
  }

  // ---------- 菜单动作 ----------
  /// 导入 Markdown：选一个或多个 .md，各自变成一篇便签。
  ///
  /// 标题用 guessTitle 猜（第一个标题行，否则第一行前 60 字），
  /// 猜不出来就退回文件名。正文保持原样——标题和正文在 MemoNest 里
  /// 本来就分开存，硬把 `# 标题` 那行删掉会破坏原本的 Markdown 结构。
  Future<void> _importNotes() async {
    final s = state.store;
    if (s == null) {
      state.statusMessage = '数据还没准备好';
      state.refresh();
      return;
    }
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(
            label: 'Markdown 文件', extensions: ['md', 'markdown', 'txt']),
        XTypeGroup(label: '所有文件'),
      ],
    );
    if (files.isEmpty) return;

    var done = 0;
    var failed = 0;
    String? lastId;
    for (final file in files) {
      try {
        final content = await File(file.path).readAsString(encoding: utf8);
        final fallback = p.basenameWithoutExtension(file.path);
        final title = guessTitle(content, fallback);
        final note = s.create(title: title, content: content);
        lastId = note.id;
        done++;
      } on Exception {
        failed++;
      }
    }

    if (lastId != null) {
      final imported = s.get(lastId);
      if (imported != null) state.selectNote(imported);
    }
    if (done == 0) {
      state.statusMessage = '导入失败';
    } else if (failed == 0) {
      state.statusMessage = done == 1 ? '已导入 1 篇便签' : '已导入 $done 篇便签';
    } else {
      state.statusMessage = '已导入 $done 篇，$failed 篇失败';
    }
    state.refresh();
  }

  Future<void> _exportNote() async {
    final note = state.current;
    if (note == null) return;
    state.saveCurrent(force: true);
    final safe = note.title.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_');
    final location = await getSaveLocation(
      suggestedName: '${safe.isEmpty ? 'note' : safe}.md',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Markdown 文件', extensions: ['md']),
        XTypeGroup(label: '所有文件'),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(note.content, encoding: utf8);
    state.statusMessage = '已导出到 ${location.path}';
    state.refresh();
  }

  Future<void> _openDataDir() async {
    final ok = await state.host.openFolder(state.paths.dataDir);
    if (ok) return;
    // 打不开就把路径摆出来让用户自己复制，比一句「失败」有用。
    state.statusMessage = '数据目录：${state.paths.dataDir}';
    state.refresh();
  }

  void _showHelp() {
    final vaultTip = state.vault != null
        ? '· 顶栏「便签 / 私密」切换普通与私密库，Ctrl+L 锁定\n'
            '· 切回「便签」会立即锁定私密库，下次进入需重新解锁\n'
            '· 忘记主密码可在解锁面板点「忘记密码？」重置（会清空私密库）\n'
        : '· 笔记文件位于 data/notes，可直接用其他编辑器编辑\n';
    _infoDialog(
      '使用说明',
      'MemoNest 便签\n\n'
          '· 顶部下拉框切换便签，「＋」新建\n'
          '· 📌 把当前便签置顶（列表最前）\n'
          '· 🗑 删除当前便签，可在「⋯ → 回收站」里恢复\n'
          '· 🔍 展开搜索，回车打开第一条，Esc 收起\n'
          '· 标题与正文自动保存，无需手动保存（Ctrl+S 仍可用）\n'
          '· 「预览」查看 Markdown 效果，Ctrl+E 切换\n'
          '· Ctrl+N 新建 / Ctrl+F 搜索 / Ctrl+D 删除\n'
          '$vaultTip'
          '· 私密库里的便签加密保存，其余便签仍是 Markdown 明文\n'
          '· OneDrive 备份可用同步文件夹，或直接登录 Microsoft 账号\n'
          '· GitHub 备份需要 Personal Access Token（repo 权限）',
    );
  }

  void _showAbout() {
    _infoDialog(
      '关于',
      'MemoNest  v2.0.0\n\n'
          '便签式的本地 Markdown 备忘录（Flutter 重写版）。\n\n'
          '项目地址：\n'
          'https://github.com/P4rfa1t/Memo-Nest\n\n'
          '数据目录：${state.paths.dataDir}',
    );
  }

  void _infoDialog(String title, String body) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Palette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(title,
            style: const TextStyle(fontSize: 15, color: Palette.fg)),
        content: SingleChildScrollView(
          child: SelectableText(
            body,
            style: const TextStyle(
                fontSize: 12.5, color: Palette.fg, height: 1.75),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了', style: TextStyle(color: Palette.muted)),
          ),
        ],
      ),
    );
  }

  Future<void> _quit() async {
    state.saveCurrent(force: true);
    if (state.config.get('general.backup_on_exit', false) == true &&
        state.hasUnsavedBackup) {
      // 等它跑完再销毁：graph 模式要发网络请求，提前 dispose 会让
      // 状态栏和 notifyListeners 撞上已释放的对象。
      try {
        await state.runBackup(label: 'exit');
      } on Object catch (e) {
        debugPrint('退出备份失败：$e');
      }
    }
    state.disposeState();
    await state.host.destroyWindow();
  }

  // ---------- 自绘标题栏 ----------
  // 系统标题栏是纯白/纯黑，和米黄纸面接在一起很割裂；这里整条换成纸面，
  // 只留三个自绘按钮，拖动、双击最大化交给平台宿主处理。
  //
  // 移动端（Android）没有窗口概念，三个按钮直接不出现。
  Widget _buildTitleBar() {
    const hoverColor = Color(0x1A8A6A1E);
    final maximized = state.maximized;

    Widget caption({
      required IconData icon,
      required VoidCallback onTap,
      bool close = false,
    }) {
      return _CaptionButton(
        icon: icon,
        onTap: onTap,
        close: close,
        hoverColor: hoverColor,
      );
    }

    return SizedBox(
      height: state.host.isDesktop
          ? MainWindow.titleBarHeight
          : MainWindow.mobileTitleBarHeight,
      // 拖动、双击最大化、右键系统菜单全部交给 Win32 的 WM_NCHITTEST
      // （见 windows/runner/flutter_window.cpp）：在 Dart 侧伪造拖动会冻结
      // 渲染线程，正是之前点顶栏必崩的原因。
      child: Row(
        children: [
          Expanded(
            // Windows 上这块区域由 WM_NCHITTEST 判成 HTCAPTION，拖动交给系统；
            // Linux 没有那个机制，只能在这里发起拖动。
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: state.host.titleBarDragInDart
                  ? (_) => state.host.startWindowDrag()
                  : null,
              onDoubleTap: state.host.titleBarDragInDart
                  ? () => state.host.toggleMaximize()
                  : null,
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _BrandMark(size: 16),
                    SizedBox(width: 7),
                    Text(
                      'MemoNest 备忘录',
                      style: TextStyle(
                        fontSize: 12,
                        color: Palette.fg,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (state.host.isDesktop) ...[
            caption(
              icon: Icons.remove,
              onTap: () => state.host.minimize(),
            ),
            caption(
              icon: maximized ? Icons.filter_none : Icons.crop_square,
              onTap: () async {
                await state.host.toggleMaximize();
                state.setMaximized(!maximized);
              },
            ),
            caption(
              icon: Icons.close,
              close: true,
              onTap: () {
                state.saveCurrent(force: true);
                state.host.closeWindow();
              },
            ),
          ],
        ],
      ),
    );
  }

  // ---------- 顶栏 ----------
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Row(
        children: [
          const Text(
            'MemoNest',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Palette.fg,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          _buildLibraryTabs(),
          const Spacer(),
          StripButton(
            label: state.previewMode ? '编辑' : '预览',
            onTap: () {
              state.previewMode = !state.previewMode;
              state.refresh();
            },
          ),
          const SizedBox(width: 4),
          StripButton(
            label: state.backupRunning ? '备份中…' : '备份',
            // 备份过程中重复点击没意义，直接忽略（runBackup 里也有护栏）。
            onTap: state.backupRunning ? () {} : () => state.runBackup(),
          ),
          const SizedBox(width: 4),
          StripButton(
            label: '⋯',
            fontSize: 16,
            onTap: () {
              setState(() {
                _menuOpen = !_menuOpen;
                _settingsOpen = false;
                _trashOpen = false;
              });
            },
          ),
          // 无边框窗口最右侧 8px 是系统的缩放热区，控件压上去
          // 松手会被当成边缘操作（实测会导致窗口直接关闭）。留 12px 余量。
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildLibraryTabs() {
    Widget tab(String label, LibraryKind kind) {
      final selected = state.library == kind;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => state.switchLibrary(kind),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE7CF87) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: Palette.fg,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Palette.strip,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          tab('便签', LibraryKind.notes),
          tab('私密', LibraryKind.vault),
        ],
      ),
    );
  }

  // ---------- 便签选择行 ----------
  Widget _buildSelector() {
    final notes = state.visibleNotes;
    final note = state.current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Palette.field,
                borderRadius: BorderRadius.circular(10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: note != null && notes.any((n) => n.id == note.id)
                      ? note.id
                      : null,
                  isExpanded: true,
                  isDense: true,
                  borderRadius: BorderRadius.circular(10),
                  dropdownColor: Palette.card,
                  icon: const Icon(Icons.expand_more,
                      size: 18, color: Palette.muted),
                  hint: Text(
                    notes.isEmpty ? '还没有便签' : '选择便签',
                    style:
                        const TextStyle(fontSize: 12.5, color: Palette.muted),
                  ),
                  style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                  items: [
                    for (final n in notes)
                      DropdownMenuItem(
                        value: n.id,
                        child: Text(
                          '${n.pinned ? '📌 ' : ''}${n.title}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, color: Palette.fg),
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    final picked = notes.firstWhere((n) => n.id == id);
                    state.selectNote(picked);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _iconAction(
            icon: Icons.add,
            tooltip: '新建便签 (Ctrl+N)',
            onTap: () => state.newNote(),
          ),
          _iconAction(
            icon:
                note?.pinned == true ? Icons.push_pin : Icons.push_pin_outlined,
            tooltip: note?.pinned == true ? '取消置顶' : '置顶当前便签',
            color: note?.pinned == true ? Palette.accentHover : Palette.muted,
            onTap: () => state.togglePin(),
          ),
          _iconAction(
            icon: Icons.search,
            tooltip: '搜索 (Ctrl+F)',
            onTap: _toggleSearch,
          ),
          _iconAction(
            icon: Icons.delete_outline,
            tooltip: '删除当前便签',
            onTap: () => _confirmDelete(),
          ),
        ],
      ),
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = Palette.muted,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final note = state.current;
    if (note == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Palette.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('删除便签',
            style: TextStyle(fontSize: 15, color: Palette.fg)),
        content: Text(
          '「${note.title}」将被移到回收站，可以在「⋯ → 回收站」里恢复。',
          style: const TextStyle(fontSize: 13, color: Palette.fg, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消', style: TextStyle(color: Palette.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除', style: TextStyle(color: Palette.danger)),
          ),
        ],
      ),
    );
    if (ok == true) state.deleteCurrent();
  }

  // ---------- 搜索行 ----------
  Widget _buildSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 0),
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Palette.field,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 16, color: Palette.muted),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '搜索标题、标签、正文…',
                  hintStyle: TextStyle(fontSize: 12.5, color: Palette.muted),
                ),
                onChanged: (value) => state.setQuery(value),
              ),
            ),
            GestureDetector(
              onTap: _toggleSearch,
              child: const Icon(Icons.close, size: 15, color: Palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 正文 ----------
  Widget _buildBody() {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      decoration: BoxDecoration(
        color: Palette.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: state.previewMode ? _buildPreview() : EditorArea(state: state),
    );
  }

  Widget _buildPreview() {
    final note = state.current;
    if (note == null) {
      return const Center(
        child: Text('没有打开的便签',
            style: TextStyle(fontSize: 13, color: Palette.muted)),
      );
    }
    // 图片相对路径要按当前库解析：私密库的 assets 在 vault/items 下。
    return MarkdownView(
        source: note.content,
        baseDir: state.store?.notesDir ?? state.paths.notesDir);
  }

  // ---------- 状态栏 ----------
  Widget _buildStatusBar() {
    final note = state.current;
    final stats = _stats(note?.content ?? '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          Text(
            state.statusMessage.isEmpty ? stats : state.statusMessage,
            style: const TextStyle(fontSize: 11, color: Palette.muted),
          ),
          const Spacer(),
          if (note != null)
            Text(
              '更新于 ${fmtTime(note.updated)}',
              style: const TextStyle(fontSize: 11, color: Palette.muted),
            ),
        ],
      ),
    );
  }

  String _stats(String content) {
    final chars = content.replaceAll(RegExp(r'\s'), '').length;
    final lines = content.isEmpty ? 0 : content.split('\n').length;
    return '$chars 字 · $lines 行';
  }
}

/// 自绘标题栏的最小化/最大化/关闭按钮。
class _CaptionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool close;
  final Color hoverColor;

  const _CaptionButton({
    required this.icon,
    required this.onTap,
    required this.hoverColor,
    this.close = false,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hover
        ? (widget.close ? const Color(0xFFE81123) : widget.hoverColor)
        : Colors.transparent;
    final iconColor = widget.close && _hover ? Colors.white : Palette.fg;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 44,
          height: MainWindow.titleBarHeight,
          color: bg,
          child: Icon(widget.icon, size: 14, color: iconColor),
        ),
      ),
    );
  }
}

/// 标题栏左侧的小图标：圆角方块 + 三行「便签」笔画，不引入位图资源。
class _BrandMark extends StatelessWidget {
  final double size;

  const _BrandMark({this.size = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Palette.strip,
        borderRadius: BorderRadius.circular(size * 0.28),
        border: Border.all(color: const Color(0xFFDCC888)),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.sticky_note_2_outlined,
          size: size * 0.72, color: Palette.muted),
    );
  }
}
