/// 「⋯」菜单：自绘卡片，条目按当前库动态生成。
///
/// 条目顺序对齐 Python 版 `_build_menu`：设置 → 库操作 → 导入/导出/数据文件夹 →
/// 删除 → 回收站 → 使用说明/关于 → 退出。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../theme.dart';

/// 菜单里可以触发的一个动作。
class MenuAction {
  final String label;
  final String shortcut;
  final VoidCallback onTap;

  const MenuAction(this.label, this.onTap, {this.shortcut = ''});
}

class MenuOverlay extends StatelessWidget {
  final AppState state;
  final VoidCallback onClose;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenTrash;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final VoidCallback onOpenDataDir;
  final VoidCallback onShowHelp;
  final VoidCallback onShowAbout;
  final VoidCallback onQuit;
  final VoidCallback onDelete;

  const MenuOverlay({
    super.key,
    required this.state,
    required this.onClose,
    required this.onOpenSettings,
    required this.onOpenTrash,
    required this.onImport,
    required this.onExport,
    required this.onOpenDataDir,
    required this.onShowHelp,
    required this.onShowAbout,
    required this.onQuit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final hasNote = state.current != null;
    final entries = <_Item>[
      _Item.action(MenuAction('设置…', () {
        onClose();
        onOpenSettings();
      }, shortcut: 'Ctrl+,')),
      const _Item.separator(),
      if (state.isVault) ...[
        _Item.action(MenuAction('移回普通便签', () {
          onClose();
          state.moveCurrentBetweenLibraries();
        })),
        _Item.action(MenuAction('锁定私密笔记库', () {
          onClose();
          state.lockVault();
        }, shortcut: 'Ctrl+L')),
      ] else
        _Item.action(MenuAction('移到私密笔记库', () {
          onClose();
          state.moveCurrentBetweenLibraries();
        })),
      const _Item.separator(),
      // 导入不看 hasNote：空库一样能导入，导完自然就有便签了。
      _Item.action(MenuAction('导入 Markdown…', () {
        onClose();
        onImport();
      })),
      _Item.action(
          MenuAction('导出为 Markdown…', () {
            onClose();
            onExport();
          }, shortcut: ''),
          enabled: hasNote),
      _Item.action(MenuAction('打开数据文件夹', () {
        onClose();
        onOpenDataDir();
      })),
      _Item.action(
          MenuAction('删除当前便签', () {
            onClose();
            onDelete();
          }, shortcut: 'Ctrl+D'),
          enabled: hasNote),
      _Item.action(MenuAction('回收站…', () {
        onClose();
        onOpenTrash();
      })),
      const _Item.separator(),
      _Item.action(MenuAction('使用说明', () {
        onClose();
        onShowHelp();
      })),
      _Item.action(MenuAction('关于 MemoNest', () {
        onClose();
        onShowAbout();
      })),
      _Item.action(MenuAction('退出 MemoNest', () {
        onClose();
        onQuit();
      })),
    ];

    return Stack(
      children: [
        // 只在下拉框以下铺一层点击关闭区：覆盖整窗的话，顶栏那三个胶囊
        // （预览/备份/⋯）会被它挡住，点了没反应。
        Positioned(
          left: 0,
          right: 0,
          top: _menuTop,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
          ),
        ),
        Positioned(
          top: _menuTop,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 202,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: Palette.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Palette.border),
                boxShadow: [
                  BoxShadow(
                    color: Palette.fg.withValues(alpha: 0.16),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in entries)
                    if (item.separator)
                      const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Divider(color: Palette.border, height: 1),
                      )
                    else
                      _MenuRow(item: item),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片顶边：标题栏(34) + 内边距(12) + 下拉框(30) = 76，留 2px 呼吸。
const double _menuTop = 78;

class _Item {
  final MenuAction? action;
  final bool separator;
  final bool enabled;

  _Item.action(MenuAction this.action, {this.enabled = true})
      : separator = false;

  const _Item.separator()
      : action = null,
        enabled = false,
        separator = true;
}

class _MenuRow extends StatefulWidget {
  final _Item item;

  const _MenuRow({required this.item});

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.item.action;
    final enabled = widget.item.enabled && action != null;
    final label = action?.label ?? '';
    final shortcut = action?.shortcut ?? '';
    final onTap = enabled ? action.onTap : null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: _hover && enabled ? Palette.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: enabled
                        ? Palette.fg
                        : Palette.muted.withValues(alpha: 0.55),
                  ),
                ),
              ),
              if (shortcut.isNotEmpty)
                Text(
                  shortcut,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Palette.muted.withValues(alpha: enabled ? 0.9 : 0.4),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
