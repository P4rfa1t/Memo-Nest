/// 轻量 Markdown 解析，与 Python 版 `core/markdown.py` 的 `parse_blocks`
/// 保持同样的块划分规则（预览效果要能对上）。
///
/// 只做解析，渲染交给 `ui/markdown_view.dart` 里的 Widget。
library;

import 'dart:convert';

class MdBlock {
  final String
      kind; // heading | paragraph | list | quote | code | hr | table | image
  final String text;
  final int level;
  final String lang;
  final List<String> items;
  final bool ordered;
  final int start;
  final List<String> header;
  final List<List<String>> rows;
  final String src;

  const MdBlock(
    this.kind, {
    this.text = '',
    this.level = 0,
    this.lang = '',
    this.items = const [],
    this.ordered = false,
    this.start = 1,
    this.header = const [],
    this.rows = const [],
    this.src = '',
  });
}

class MdSpan {
  final String text;
  final Set<String> styles;
  final String? url;

  const MdSpan(this.text, {this.styles = const {}, this.url});

  bool get bold => styles.contains('bold');
  bool get italic => styles.contains('italic');
  bool get code => styles.contains('code');
  bool get strike => styles.contains('strike');
  bool get link => styles.contains('link');
}

final RegExp _fenceRe = RegExp(r'^\s*(`{3,}|~{3,})\s*([\w+#.-]*)');
final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _hrRe = RegExp(r'^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$');
final RegExp _ulRe = RegExp(r'^(\s*)([-*+])\s+(.*)$');
final RegExp _olRe = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final RegExp _quoteRe = RegExp(r'^\s*>\s?(.*)$');
final RegExp _imageLineRe = RegExp(
  r'^\s*!\[(?<alt>[^\]]*)\]\((?<src>[^)\s]+)(?:\s+"[^"]*")?\)\s*$',
);

bool _isSepRow(String line) {
  final trimmed = line.trim().replaceAll(RegExp(r'^\||\|$'), '').trim();
  if (trimmed.isEmpty || !trimmed.contains('|')) return false;
  return trimmed
      .split('|')
      .every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell.trim()));
}

List<String> _splitRow(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return trimmed.split('|').map((c) => c.trim()).toList();
}

bool _blockStart(String line, List<String> lines, int index) {
  if (line.trim().isEmpty) return true;
  if (_fenceRe.hasMatch(line) ||
      _headingRe.hasMatch(line) ||
      _hrRe.hasMatch(line)) {
    return true;
  }
  if (_imageLineRe.hasMatch(line)) return true;
  if (_quoteRe.hasMatch(line) || _ulRe.hasMatch(line) || _olRe.hasMatch(line)) {
    return true;
  }
  if (line.trimLeft().startsWith('|') &&
      index + 1 < lines.length &&
      _isSepRow(lines[index + 1])) {
    return true;
  }
  return false;
}

bool _isWide(String ch) {
  if (ch.isEmpty) return false;
  final code = ch.runes.first;
  // CJK 与全角字符区间，近似 Python unicodedata.east_asian_width 的 W/F
  return (code >= 0x1100 && code <= 0x115F) ||
      (code >= 0x2E80 && code <= 0xA4CF) ||
      (code >= 0xAC00 && code <= 0xD7A3) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFE30 && code <= 0xFE6F) ||
      (code >= 0xFF00 && code <= 0xFF60) ||
      (code >= 0xFFE0 && code <= 0xFFE6);
}

/// 合并段落内的软换行：中文之间不加空格，英文之间加空格。
String _joinLines(List<String> lines) {
  var text = '';
  for (final line in lines) {
    if (text.isEmpty) {
      text = line;
    } else if (_isWide(text[text.length - 1]) || _isWide(line[0])) {
      text += line;
    } else {
      text += ' $line';
    }
  }
  return text;
}

List<MdBlock> parseBlocks(String md) {
  final lines = md.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final blocks = <MdBlock>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    final fence = _fenceRe.firstMatch(line);
    if (fence != null) {
      final marker = fence.group(1)!;
      final lang = fence.group(2) ?? '';
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(marker)) {
        body.add(lines[i]);
        i++;
      }
      i++;
      blocks.add(MdBlock('code', text: body.join('\n'), lang: lang));
      continue;
    }

    final image = _imageLineRe.firstMatch(line);
    if (image != null) {
      blocks.add(MdBlock('image',
          text: image.namedGroup('alt') ?? '',
          src: image.namedGroup('src') ?? ''));
      i++;
      continue;
    }

    if (_hrRe.hasMatch(line)) {
      blocks.add(const MdBlock('hr'));
      i++;
      continue;
    }

    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      blocks.add(MdBlock('heading',
          text: heading.group(2)!.trim(), level: heading.group(1)!.length));
      i++;
      continue;
    }

    // 表格：当前行以 | 开头且下一行是分隔行
    if (line.trimLeft().startsWith('|') &&
        i + 1 < lines.length &&
        _isSepRow(lines[i + 1])) {
      final header = _splitRow(line);
      final rows = <List<String>>[];
      i += 2;
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        rows.add(_splitRow(lines[i]));
        i++;
      }
      blocks.add(MdBlock('table', header: header, rows: rows));
      continue;
    }

    if (_quoteRe.hasMatch(line)) {
      final body = <String>[];
      while (i < lines.length) {
        final match = _quoteRe.firstMatch(lines[i]);
        if (match == null) break;
        body.add(match.group(1) ?? '');
        i++;
      }
      blocks.add(MdBlock('quote', text: body.join('\n')));
      continue;
    }

    final ul = _ulRe.firstMatch(line);
    final ol = _olRe.firstMatch(line);
    if (ul != null || ol != null) {
      final ordered = ol != null;
      final start = ordered ? int.tryParse(ol.group(2)!) ?? 1 : 1;
      final items = <String>[];
      while (i < lines.length) {
        final cur = lines[i];
        final match = ordered ? _olRe.firstMatch(cur) : _ulRe.firstMatch(cur);
        if (match == null) break;
        items.add(match.group(3)!.trim());
        i++;
      }
      blocks.add(MdBlock('list', items: items, ordered: ordered, start: start));
      continue;
    }

    // 段落：吃到空行或下一个块起点
    final paragraph = <String>[];
    while (i < lines.length) {
      if (paragraph.isNotEmpty && _blockStart(lines[i], lines, i)) break;
      if (lines[i].trim().isEmpty) break;
      paragraph.add(lines[i].trim());
      i++;
    }
    if (paragraph.isNotEmpty) {
      blocks.add(MdBlock('paragraph', text: _joinLines(paragraph)));
    } else {
      i++;
    }
  }

  return blocks;
}

final RegExp _linkRe = RegExp(r'\[(?<text>[^\]]*)\]\((?<url>[^)\s]+)\)');
final RegExp _codeRe = RegExp(r'`(?<code>[^`\n]+)`');
final RegExp _boldRe = RegExp(r'\*\*(?<b1>[^*\n]+)\*\*|__(?<b2>[^_\n]+)__');
final RegExp _strikeRe = RegExp(r'~~(?<s>[^~\n]+)~~');
final RegExp _italicRe = RegExp(
  r'\*(?<i1>[^*\n]+)\*|_(?<i2>[^_\n]+)_',
);
final RegExp _escapeRe = RegExp(r'\\([\\`*_{}\[\]()#+\-.!~|>])');

/// 行内解析：把一行文本拆成带样式的片段。
///
/// 走一遍扫描，避免正则互相吞掉（`**粗**` 里的 `*` 不能被斜体规则先吃掉）。
List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  final buffer = StringBuffer();
  var i = 0;

  void flush([Set<String> styles = const {}]) {
    if (buffer.isEmpty) return;
    spans.add(MdSpan(buffer.toString(), styles: styles));
    buffer.clear();
  }

  while (i < text.length) {
    final rest = text.substring(i);

    final escape = _escapeRe.firstMatch(rest);
    if (escape != null && escape.start == 0) {
      buffer.write(escape.group(1));
      i += escape.group(0)!.length;
      continue;
    }

    final code = _codeRe.firstMatch(rest);
    if (code != null && code.start == 0) {
      flush();
      spans.add(MdSpan(code.namedGroup('code')!, styles: const {'code'}));
      i += code.group(0)!.length;
      continue;
    }

    final link = _linkRe.firstMatch(rest);
    if (link != null && link.start == 0) {
      flush();
      spans.add(MdSpan(
        link.namedGroup('text')!,
        styles: const {'link'},
        url: link.namedGroup('url'),
      ));
      i += link.group(0)!.length;
      continue;
    }

    final bold = _boldRe.firstMatch(rest);
    if (bold != null && bold.start == 0) {
      flush();
      final inner = bold.namedGroup('b1') ?? bold.namedGroup('b2') ?? '';
      spans.addAll(parseInline(inner).map((s) => MdSpan(
            s.text,
            styles: {...s.styles, 'bold'},
            url: s.url,
          )));
      i += bold.group(0)!.length;
      continue;
    }

    final strike = _strikeRe.firstMatch(rest);
    if (strike != null && strike.start == 0) {
      flush();
      spans.add(MdSpan(strike.namedGroup('s')!, styles: const {'strike'}));
      i += strike.group(0)!.length;
      continue;
    }

    final italic = _italicRe.firstMatch(rest);
    if (italic != null && italic.start == 0) {
      flush();
      final inner = italic.namedGroup('i1') ?? italic.namedGroup('i2') ?? '';
      spans.addAll(parseInline(inner).map((s) => MdSpan(
            s.text,
            styles: {...s.styles, 'italic'},
            url: s.url,
          )));
      i += italic.group(0)!.length;
      continue;
    }

    buffer.write(text[i]);
    i++;
  }

  flush();
  return spans;
}

/// 去掉 Markdown 标记，用于列表标题、搜索结果摘要。
String stripMarkers(String text) {
  var out = text;
  String pick(RegExpMatch m, List<String> names) {
    for (final name in names) {
      final value = m.namedGroup(name);
      if (value != null) return value;
    }
    return '';
  }

  out = out.replaceAllMapped(
      _linkRe, (m) => pick(m as RegExpMatch, const ['text']));
  out = out.replaceAllMapped(
      _boldRe, (m) => pick(m as RegExpMatch, const ['b1', 'b2']));
  out = out.replaceAllMapped(
      _italicRe, (m) => pick(m as RegExpMatch, const ['i1', 'i2']));
  out = out.replaceAllMapped(
      _strikeRe, (m) => pick(m as RegExpMatch, const ['s']));
  out = out.replaceAllMapped(
      _codeRe, (m) => pick(m as RegExpMatch, const ['code']));
  out = out.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  out = out.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  out = out.replaceAll(RegExp(r'^\s*\d+[.)]\s+', multiLine: true), '');
  out = out.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
  return out.trim();
}

/// 估算显示宽度（CJK 算 2 列），列表里用来截断标题。
int displayWidth(String text) {
  var width = 0;
  for (final ch in text.split('')) {
    width += _isWide(ch) ? 2 : 1;
  }
  return width;
}

/// 判断文件是不是 UTF-8 文本，给图片资源做个小工具用。
bool looksLikeUtf8(List<int> bytes) {
  try {
    utf8.decode(bytes);
    return true;
  } on FormatException {
    return false;
  }
}
