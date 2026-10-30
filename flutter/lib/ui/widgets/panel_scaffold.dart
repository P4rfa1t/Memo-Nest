/// 内嵌面板的统一外壳：半透明遮罩 + 圆角卡片 + 标题行 + 关闭按钮。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class PanelScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  final VoidCallback onClose;
  final double maxWidth;
  final double maxHeight;

  const PanelScaffold({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.maxWidth = 400,
    this.maxHeight = 560,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(color: Palette.fg.withValues(alpha: 0.12)),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
            child: Material(
              color: Colors.transparent,
              child: Container(
                decoration: BoxDecoration(
                  color: Palette.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Palette.border),
                  boxShadow: [
                    BoxShadow(
                      color: Palette.fg.withValues(alpha: 0.18),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 10, 8),
                      child: Row(
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Palette.fg,
                            ),
                          ),
                          const Spacer(),
                          _CloseButton(onTap: onClose),
                        ],
                      ),
                    ),
                    const Divider(color: Palette.border, height: 1),
                    Flexible(child: child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;

  const _CloseButton({required this.onTap});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? Palette.strip : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: const Icon(Icons.close, size: 16, color: Palette.muted),
        ),
      ),
    );
  }
}
