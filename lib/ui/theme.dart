/// 调色板与排版常量：与 Python 版 `app.py` 的 PALETTE 完全一致，
/// 两个版本看起来才是同一个产品。
library;

import 'package:flutter/material.dart';

class Palette {
  static const Color bg = Color(0xFFFFF8D9);
  static const Color panel = Color(0xFFFFF8D9);
  static const Color card = Color(0xFFFFFDF2);
  static const Color field = Color(0xFFFBF1C7);
  static const Color strip = Color(0xFFF5E7B0);
  static const Color fg = Color(0xFF3B3323);
  static const Color muted = Color(0xFF93865B);
  static const Color accent = Color(0xFFE3B23C);
  static const Color accentHover = Color(0xFFD6A22C);
  static const Color link = Color(0xFF2563EB);
  static const Color border = Color(0xFFEDE0AC);
  static const Color codeBg = Color(0xFFF6E9B5);
  static const Color codeFg = Color(0xFF8A5A00);
  static const Color selection = Color(0xFFF0DFA0);
  static const Color danger = Color(0xFFC0392B);
}

/// 便签纸主题：圆角、无阴影、细边框，和 Tk 版的手绘卡片语言一致。
ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Palette.bg,
    colorScheme: const ColorScheme.light(
      primary: Palette.accent,
      onPrimary: Palette.fg,
      secondary: Palette.accentHover,
      surface: Palette.card,
      onSurface: Palette.fg,
      outline: Palette.border,
    ),
    fontFamily: 'Microsoft YaHei UI',
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Palette.fg,
      displayColor: Palette.fg,
    ),
    dividerTheme: const DividerThemeData(
      color: Palette.border,
      thickness: 1,
      space: 1,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: Palette.fg.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      waitDuration: const Duration(milliseconds: 450),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Palette.accent, width: 1.4),
      ),
      hintStyle: const TextStyle(color: Palette.muted),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Palette.fg,
      selectionColor: Palette.selection,
      selectionHandleColor: Palette.accent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(Palette.border),
      radius: const Radius.circular(4),
      thickness: WidgetStateProperty.all(6),
    ),
  );
}

/// 正文与等宽的字体族，跟随系统，不做字体打包（体积换一致性是划算的）。
const String kBodyFont = 'Microsoft YaHei UI';
const String kMonoFont = 'Consolas';
