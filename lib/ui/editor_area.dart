/// 正文编辑区：标题、标签、分隔线、Markdown 编辑器。
///
/// 用 Flutter 的 `TextField`，中文输入走系统 IME，候选窗是系统现代样式。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/toast.dart';
import '../core/models.dart';
import '../core/note_store.dart';
import '../platform/png.dart';
import 'theme.dart';

class EditorArea extends StatefulWidget {
  final AppState state;

  const EditorArea({super.key, required this.state});

  @override
  State<EditorArea> createState() => _EditorAreaState();
}

class _EditorAreaState extends State<EditorArea> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _tagsController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _tagsFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode();
  final UndoHistoryController _undo = UndoHistoryController();
  String? _boundNoteId;

  /// 上次灌入输入框时的内容版本，见 [AppState.contentRevision]。
  int _boundRevision = 0;

  /// 右键菜单开着时记下它的关闭回调。
  ///
  /// 菜单挂在 Overlay 里、不在输入框的焦点链上，Esc 到不了它；
  /// 所以用 HardwareKeyboard 全局钩子截一次 Esc 主动收起来。
  VoidCallback? _menuDismiss;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_sync);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _sync();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    final dismiss = _menuDismiss;
    if (dismiss == null) return false;
    _menuDismiss = null;
    dismiss();
    return true;
  }

  void _dismissContextMenu() {
    final dismiss = _menuDismiss;
    _menuDismiss = null;
    dismiss?.call();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    state.removeListener(_sync);
    _titleController.dispose();
    _tagsController.dispose();
    _bodyController.dispose();
    _titleFocus.dispose();
    _tagsFocus.dispose();
    _bodyFocus.dispose();
    _undo.dispose();
    super.dispose();
  }

  /// 只在「换了便签」时把内容灌进输入框，避免每敲一个字就重置光标。
  void _sync() {
    if (!mounted) return;
    final note = state.current;
    if (note == null) {
      _boundNoteId = null;
      if (_titleController.text.isNotEmpty) _titleController.clear();
      if (_tagsController.text.isNotEmpty) _tagsController.clear();
      if (_bodyController.text.isNotEmpty) _bodyController.clear();
      return;
    }
    // 同一个 id 但磁盘内容被外部改过（GitHub 同步取回了新版本）时也要重灌，
    // 否则输入框还留着旧文字，下一次自动保存又把旧内容写回去。
    if (note.id == _boundNoteId && state.contentRevision == _boundRevision) {
      return;
    }
    _boundNoteId = note.id;
    _boundRevision = state.contentRevision;
    _titleController.text = note.title;
    _tagsController.text = note.tags.join(', ');
    _bodyController.text = note.content;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final note = state.current;
    if (note == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sticky_note_2_outlined,
                size: 34, color: Palette.muted),
            const SizedBox(height: 10),
            const Text(
              '还没有便签',
              style: TextStyle(fontSize: 13, color: Palette.muted),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => state.newNote(),
              child: const Text('新建一张', style: TextStyle(color: Palette.link)),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: TextField(
            controller: _titleController,
            focusNode: _titleFocus,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Palette.fg,
              height: 1.45,
            ),
            decoration: const InputDecoration(
              isDense: true,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 6),
              hintText: '标题',
              hintStyle: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Color(0xFFC9BC8C),
              ),
            ),
            textInputAction: TextInputAction.next,
            onSubmitted: (_) => _bodyFocus.requestFocus(),
            onChanged: (value) => state.updateTitle(value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
          child: Row(
            children: [
              const Text('#',
                  style: TextStyle(fontSize: 11.5, color: Palette.muted)),
              const SizedBox(width: 5),
              Expanded(
                child: TextField(
                  controller: _tagsController,
                  focusNode: _tagsFocus,
                  style: const TextStyle(
                      fontSize: 11, color: Palette.muted, height: 1.4),
                  decoration: const InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 3),
                    hintText: '添加标签，用逗号分隔',
                    hintStyle:
                        TextStyle(fontSize: 11, color: Color(0xFFC9BC8C)),
                  ),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _bodyFocus.requestFocus(),
                  onChanged: (value) => state.updateTags(value),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _metaLabel(note),
                style: const TextStyle(fontSize: 10.5, color: Palette.muted),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Divider(color: Palette.border, height: 1),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: _buildBodyField(),
          ),
        ),
      ],
    );
  }

  Widget _buildBodyField() {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyV,
            control: true, shift: true): _pasteImage,
      },
      child: TextField(
        controller: _bodyController,
        focusNode: _bodyFocus,
        undoController: _undo,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 12.5, height: 1.68, color: Palette.fg),
        cursorColor: Palette.accent,
        decoration: const InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: '开始写点什么…',
          hintStyle: TextStyle(fontSize: 12.5, color: Palette.muted),
        ),
        onChanged: (value) => state.updateContent(value),
        contextMenuBuilder: (context, editableTextState) {
          return _buildContextMenu(context, editableTextState);
        },
      ),
    );
  }

  /// 右键菜单：自绘卡片，条目状态跟随选区与剪贴板。
  Widget _buildContextMenu(
      BuildContext context, EditableTextState editableTextState) {
    final value = editableTextState.textEditingValue;
    final hasSelection =
        value.selection.isValid && !value.selection.isCollapsed;
    final canUndo = _undo.value.canUndo;
    final canRedo = _undo.value.canRedo;
    final hasImage = state.host.clipboardHasImage();

    final items = <_MenuEntry>[
      _MenuEntry('撤销', 'Ctrl+Z', canUndo ? () => _undo.undo() : null),
      _MenuEntry('重做', 'Ctrl+Y', canRedo ? () => _undo.redo() : null),
      const _MenuEntry.separator(),
      _MenuEntry(
          '剪切',
          'Ctrl+X',
          hasSelection
              ? () =>
                  editableTextState.cutSelection(SelectionChangedCause.toolbar)
              : null),
      _MenuEntry(
          '复制',
          'Ctrl+C',
          hasSelection
              ? () =>
                  editableTextState.copySelection(SelectionChangedCause.toolbar)
              : null),
      _MenuEntry('粘贴', 'Ctrl+V',
          () => editableTextState.pasteText(SelectionChangedCause.toolbar)),
      _MenuEntry('粘贴图片', 'Ctrl+Shift+V', hasImage ? _pasteImage : null),
      const _MenuEntry.separator(),
      _MenuEntry('全选', 'Ctrl+A',
          () => editableTextState.selectAll(SelectionChangedCause.toolbar)),
      const _MenuEntry.separator(),
      _MenuEntry('插入当前时间', '', () => _insertTime()),
    ];

    final anchor = editableTextState.contextMenuAnchors.primaryAnchor;
    // 记下关闭方式，供 Esc 钩子复用；卡片销毁时清掉，避免调已失效的 state。
    _menuDismiss = () {
      _menuDismiss = null;
      editableTextState.hideToolbar();
    };
    return _ContextMenuCard(
      anchor: anchor,
      entries: items,
      onDismiss: _dismissContextMenu,
      onClosed: () => _menuDismiss = null,
    );
  }

  void _insertTime() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
    _insertAtCursor(stamp);
  }

  /// 粘贴剪贴板图片：落盘到 notes/assets/，正文插入 Markdown 图片语法。
  void _pasteImage() {
    final note = state.current;
    if (note == null) {
      state.showToast('先选一张便签', kind: ToastKind.error);
      return;
    }
    final bitmap = state.host.readClipboardBitmap();
    if (bitmap == null) {
      state.showToast('剪贴板里没有可粘贴的图片', kind: ToastKind.error);
      return;
    }
    try {
      final png = encodeBgrPng(
        width: bitmap.width,
        height: bitmap.height,
        bitCount: bitmap.bitCount,
        pixels: bitmap.pixels,
      );
      final store = state.store;
      if (store is! NoteStore) {
        state.showToast('私密库暂不支持粘贴图片', kind: ToastKind.error);
        return;
      }
      final rel = store.saveAsset(png, note.title);
      final alt = note.title.isEmpty ? '图片' : note.title;
      _insertAtCursor('\n![$alt]($rel)\n');
      state.showToast(
        '已粘贴图片 ${bitmap.width}×${bitmap.height}',
        kind: ToastKind.success,
      );
    } on Exception catch (e) {
      state.showToast('粘贴图片失败：$e', kind: ToastKind.error);
    }
  }

  void _insertAtCursor(String text) {
    final value = _bodyController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final next = value.text.replaceRange(start, end, text);
    _bodyController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    state.updateContent(next);
    _bodyFocus.requestFocus();
  }

  String _metaLabel(Note note) {
    final chars = note.content.replaceAll(RegExp(r'\s'), '').length;
    final lines = note.content.isEmpty ? 0 : note.content.split('\n').length;
    return '$chars 字 · $lines 行';
  }
}

class _MenuEntry {
  final String label;
  final String shortcut;
  final VoidCallback? onTap;
  final bool separator;

  const _MenuEntry(this.label, this.shortcut, this.onTap) : separator = false;
  const _MenuEntry.separator()
      : label = '',
        shortcut = '',
        onTap = null,
        separator = true;

  bool get enabled => onTap != null;
}

/// 自绘右键菜单：圆角卡片、悬停高亮、禁用条目灰显。
class _ContextMenuCard extends StatefulWidget {
  final Offset anchor;
  final List<_MenuEntry> entries;
  final VoidCallback onDismiss;
  final VoidCallback? onClosed;

  const _ContextMenuCard({
    required this.anchor,
    required this.entries,
    required this.onDismiss,
    this.onClosed,
  });

  @override
  State<_ContextMenuCard> createState() => _ContextMenuCardState();
}

class _ContextMenuCardState extends State<_ContextMenuCard> {
  int _hover = -1;

  @override
  void dispose() {
    widget.onClosed?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const rowHeight = 30.0;
    const separatorHeight = 9.0;
    const width = 176.0;
    var height = 12.0;
    for (final entry in widget.entries) {
      height += entry.separator ? separatorHeight : rowHeight;
    }

    // 贴着窗口右/下边缘右键时卡片要往回收，否则会被裁掉一半。
    final media = MediaQuery.of(context);
    final left = widget.anchor.dx.clamp(4.0, media.size.width - width - 4);
    final top = widget.anchor.dy.clamp(4.0, media.size.height - height - 4);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            onSecondaryTap: widget.onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: width,
              height: height,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: Palette.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Palette.border),
                boxShadow: [
                  BoxShadow(
                    color: Palette.fg.withValues(alpha: 0.14),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.entries.length; i++)
                    widget.entries[i].separator
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            child: Divider(color: Palette.border, height: 1),
                          )
                        : _buildRow(i, widget.entries[i]),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(int index, _MenuEntry entry) {
    final hovered = _hover == index && entry.enabled;
    return MouseRegion(
      cursor:
          entry.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = index),
      onExit: (_) => setState(() => _hover = -1),
      child: GestureDetector(
        onTap: entry.enabled
            ? () {
                entry.onTap!();
                widget.onDismiss();
              }
            : null,
        child: Container(
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: hovered ? Palette.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Text(
                entry.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: entry.enabled
                      ? Palette.fg
                      : Palette.muted.withValues(alpha: 0.55),
                ),
              ),
              const Spacer(),
              if (entry.shortcut.isNotEmpty)
                Text(
                  entry.shortcut,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Palette.muted
                        .withValues(alpha: entry.enabled ? 1 : 0.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
