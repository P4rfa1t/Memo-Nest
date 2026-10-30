/// 顶栏的小胶囊按钮：和 Tk 版 `_strip_button` 同一套视觉
/// （浅黄底、细边框、圆角 8、hover 变深）。
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class StripButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final double fontSize;
  final EdgeInsets padding;

  const StripButton({
    super.key,
    required this.label,
    required this.onTap,
    this.fontSize = 11.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
  });

  @override
  State<StripButton> createState() => _StripButtonState();
}

class _StripButtonState extends State<StripButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: widget.padding,
          decoration: BoxDecoration(
            color: _hover ? const Color(0xFFEFDFA0) : Palette.strip,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFDCC888)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.fontSize,
              color: Palette.fg,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }
}
