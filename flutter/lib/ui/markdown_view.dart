/// Markdown 预览：把 `core/markdown.dart` 解析出的块渲染成 Widget。
///
/// 与 Tk 版的视觉对齐：标题按级缩放、行内代码带底色、引用左侧竖线、
/// 代码块浅黄底、表格细边框、分隔线一条淡色横线。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/markdown.dart';
import 'theme.dart';

class MarkdownView extends StatelessWidget {
  final String source;

  /// 图片相对路径（`assets/xxx.png`）相对这个目录解析。
  final String? baseDir;

  const MarkdownView({super.key, required this.source, this.baseDir});

  @override
  Widget build(BuildContext context) {
    final blocks = parseBlocks(source);
    if (blocks.isEmpty) {
      return const Center(
        child: Text('这里还没有内容', style: TextStyle(color: Palette.muted, fontSize: 13)),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
        itemCount: blocks.length,
        itemBuilder: (context, index) => _buildBlock(context, blocks[index]),
      ),
    );
  }

  Widget _buildBlock(BuildContext context, MdBlock block) {
    switch (block.kind) {
      case 'heading':
        final sizes = {1: 24.0, 2: 20.0, 3: 17.0, 4: 15.0, 5: 14.0, 6: 13.0};
        return Padding(
          padding: EdgeInsets.only(top: block.level == 1 ? 10 : 14, bottom: 6),
          child: _inline(
            context,
            block.text,
            baseStyle: TextStyle(
              fontSize: sizes[block.level] ?? 13,
              fontWeight: FontWeight.w700,
              height: 1.35,
              color: Palette.fg,
            ),
          ),
        );

      case 'paragraph':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _inline(
            context,
            block.text,
            baseStyle: const TextStyle(fontSize: 13.5, height: 1.62, color: Palette.fg),
          ),
        );

      case 'code':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(10),
          width: double.infinity,
          decoration: BoxDecoration(
            color: Palette.codeBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.border),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              block.text,
              style: const TextStyle(
                fontFamily: kMonoFont,
                fontSize: 12.5,
                height: 1.55,
                color: Palette.codeFg,
              ),
            ),
          ),
        );

      case 'quote':
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: Palette.accent, width: 3)),
          ),
          child: _inline(
            context,
            block.text,
            baseStyle: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Palette.muted,
              fontStyle: FontStyle.italic,
            ),
          ),
        );

      case 'list':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < block.items.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          block.ordered ? '${block.start + i}.' : '•',
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: Palette.muted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: _inline(
                          context,
                          block.items[i],
                          baseStyle: const TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: Palette.fg,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );

      case 'table':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Table(
            border: TableBorder.all(color: Palette.border, width: 1),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Palette.field),
                children: [
                  for (final cell in block.header)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      child: Text(
                        cell,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Palette.fg,
                        ),
                      ),
                    ),
                ],
              ),
              for (final row in block.rows)
                TableRow(
                  children: [
                    for (final cell in row)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        child: Text(
                          cell,
                          style: const TextStyle(fontSize: 12.5, color: Palette.fg),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );

      case 'hr':
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(color: Palette.border, height: 1),
        );

      case 'image':
        return _buildImage(block);

      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildImage(MdBlock block) {
    final photo = _resolveImage(block.src);
    if (photo == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          '[图片：${block.text.isEmpty ? block.src : block.text}]',
          style: const TextStyle(fontSize: 12.5, color: Palette.muted),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            photo,
            errorBuilder: (_, __, ___) => Text(
              '[图片：${block.text}]',
              style: const TextStyle(fontSize: 12.5, color: Palette.muted),
            ),
          ),
        ),
      ),
    );
  }

  File? _resolveImage(String src) {
    if (src.isEmpty) return null;
    final lower = src.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return null;
    var path = src;
    if (!p.isAbsolute(path)) {
      final base = baseDir;
      if (base == null) return null;
      path = p.join(base, path);
    }
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  /// 行内样式渲染：按 span 的样式表拼 TextSpan，链接可点击。
  Widget _inline(BuildContext context, String text, {required TextStyle baseStyle}) {
    final spans = parseInline(text);
    if (spans.isEmpty) {
      return Text('', style: baseStyle);
    }
    return RichText(
      text: TextSpan(
        children: [
          for (final span in spans) _spanFor(context, span, baseStyle),
        ],
      ),
    );
  }

  InlineSpan _spanFor(BuildContext context, MdSpan span, TextStyle baseStyle) {
    var style = baseStyle;
    if (span.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (span.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (span.strike) style = style.copyWith(decoration: TextDecoration.lineThrough);
    if (span.code) {
      style = style.copyWith(
        fontFamily: kMonoFont,
        fontSize: (style.fontSize ?? 13) - 0.5,
        color: Palette.codeFg,
        backgroundColor: Palette.codeBg,
      );
    }
    if (span.link) {
      style = style.copyWith(color: Palette.link, decoration: TextDecoration.underline);
      final url = span.url;
      if (url == null || url.isEmpty) {
        return TextSpan(text: span.text, style: style);
      }
      return TextSpan(
        text: span.text,
        style: style,
        recognizer: TapGestureRecognizer()
          ..onTap = () => _openUrl(url),
      );
    }
    return TextSpan(text: span.text, style: style);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Exception {
      // 打不开就静默，别在预览里弹错误
    }
  }
}
