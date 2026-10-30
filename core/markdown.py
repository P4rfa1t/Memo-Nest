"""轻量 Markdown 解析与 Tkinter 预览渲染（不依赖第三方库）。

支持：标题、段落、加粗/斜体/删除线、行内代码、代码块、
有序/无序/任务列表、引用、分隔线、链接、图片占位、表格。
"""

from __future__ import annotations

import os
import re
import unicodedata
import webbrowser
from dataclasses import dataclass, field

HEADING_SIZES = {1: 20, 2: 17, 3: 15, 4: 13, 5: 12, 6: 11}

FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})\s*([\w+#.-]*)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
HR_RE = re.compile(r"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})$")
UL_RE = re.compile(r"^(\s*)([-*+])\s+(.*)$")
OL_RE = re.compile(r"^(\s*)(\d+)[.)]\s+(.*)$")
QUOTE_RE = re.compile(r"^\s*>\s?(.*)$")

INLINE_RE = re.compile(
    r"`(?P<code>[^`\n]+)`"
    r"|!\[(?P<img_alt>[^\]\n]*)\]\((?P<img_url>[^)\s]+)\)"
    r"|\[(?P<link_text>[^\]\n]*)\]\((?P<link_url>[^)\s]+)\)"
    r"|\*\*(?P<b1>[^*\n]+)\*\*"
    r"|__(?P<b2>[^_\n]+)__"
    r"|~~(?P<strike>[^~\n]+)~~"
    r"|\*(?P<i1>[^*\n]+)\*"
    r"|_(?P<i2>[^_\n]+)_"
)
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"']+")
ESCAPE_RE = re.compile(r"\\([\\`*_{}\[\]()#+\-.!~|>])")
# 独占一行的图片：![alt](path)。和正文混排的图片不单独成块，按行内文本处理。
IMAGE_LINE_RE = re.compile(r"^\s*!\[(?P<alt>[^\]]*)\]\((?P<src>[^)\s]+)(?:\s+\"[^\"]*\")?\)\s*$")


@dataclass
class Block:
    kind: str
    text: str = ""
    level: int = 0
    lang: str = ""
    items: list[str] = field(default_factory=list)
    ordered: bool = False
    start: int = 1
    header: list[str] = field(default_factory=list)
    rows: list[list[str]] = field(default_factory=list)
    src: str = ""


@dataclass
class Span:
    text: str
    styles: frozenset[str] = frozenset()
    url: str | None = None


# --------------------------------------------------------------------------
# 块级解析
# --------------------------------------------------------------------------
def _is_sep_row(line: str) -> bool:
    line = line.strip().strip("|").strip()
    if not line or "|" not in line:
        return False
    return all(re.fullmatch(r":?-{2,}:?", cell.strip()) for cell in line.split("|"))


def _split_row(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


def _block_start(line: str, lines: list[str], index: int) -> bool:
    if not line.strip():
        return True
    if FENCE_RE.match(line) or HEADING_RE.match(line) or HR_RE.match(line):
        return True
    if IMAGE_LINE_RE.match(line):
        return True
    if QUOTE_RE.match(line) or UL_RE.match(line) or OL_RE.match(line):
        return True
    if line.lstrip().startswith("|") and index + 1 < len(lines) and _is_sep_row(lines[index + 1]):
        return True
    return False


def _is_wide(ch: str) -> bool:
    return bool(ch) and unicodedata.east_asian_width(ch) in ("W", "F")


def _join_lines(lines: list[str]) -> str:
    """合并段落内的软换行：中文之间不加空格，英文之间加空格。"""
    text = ""
    for line in lines:
        if not text:
            text = line
        elif _is_wide(text[-1]) or _is_wide(line[0]):
            text += line
        else:
            text += " " + line
    return text


def parse_blocks(md: str) -> list[Block]:
    lines = (md or "").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks: list[Block] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue

        fence = FENCE_RE.match(line)
        if fence:
            marker = fence.group(1)
            lang = fence.group(2)
            body: list[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith(marker):
                body.append(lines[i])
                i += 1
            i += 1
            blocks.append(Block("code", text="\n".join(body), lang=lang))
            continue

        image = IMAGE_LINE_RE.match(line)
        if image:
            blocks.append(
                Block("image", text=image.group("alt"), src=image.group("src"))
            )
            i += 1
            continue

        if HR_RE.match(line):
            blocks.append(Block("hr"))
            i += 1
            continue

        heading = HEADING_RE.match(line)
        if heading:
            blocks.append(
                Block("heading", text=heading.group(2).strip(), level=len(heading.group(1)))
            )
            i += 1
            continue

        if line.lstrip().startswith("|") and i + 1 < len(lines) and _is_sep_row(lines[i + 1]):
            header = _split_row(line)
            i += 2
            rows: list[list[str]] = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(_split_row(lines[i]))
                i += 1
            blocks.append(Block("table", header=header, rows=rows))
            continue

        if QUOTE_RE.match(line):
            body = []
            while i < len(lines) and QUOTE_RE.match(lines[i]):
                body.append(QUOTE_RE.match(lines[i]).group(1))
                i += 1
            blocks.append(Block("quote", text="\n".join(body)))
            continue

        unordered = UL_RE.match(line)
        ordered = OL_RE.match(line)
        if unordered or ordered:
            is_ordered = bool(ordered and not unordered)
            items: list[str] = []
            start = int(ordered.group(2)) if is_ordered and ordered else 1
            while i < len(lines):
                mu = UL_RE.match(lines[i])
                mo = OL_RE.match(lines[i])
                if is_ordered and mo:
                    items.append(mo.group(3).strip())
                elif not is_ordered and mu:
                    items.append(mu.group(3).strip())
                else:
                    break
                i += 1
            blocks.append(Block("list", items=items, ordered=is_ordered, start=start))
            continue

        paragraph: list[str] = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not _block_start(lines[i], lines, i):
            paragraph.append(lines[i].strip())
            i += 1
        blocks.append(Block("paragraph", text=_join_lines(paragraph)))

    return blocks


# --------------------------------------------------------------------------
# 行内解析
# --------------------------------------------------------------------------
def _plain_spans(text: str, base: frozenset[str]) -> list[Span]:
    spans: list[Span] = []
    pos = 0
    for match in URL_RE.finditer(text):
        if match.start() > pos:
            spans.append(Span(text[pos : match.start()], base))
        spans.append(Span(match.group(0), base | {"link"}, match.group(0)))
        pos = match.end()
    if pos < len(text):
        spans.append(Span(text[pos:], base))
    return spans


_ESCAPE_BASE = 0xE000


def _mask_escapes(text: str) -> str:
    """把反斜杠转义替换成私用区字符，避免被行内语法匹配。"""
    return ESCAPE_RE.sub(lambda m: chr(_ESCAPE_BASE + ord(m.group(1))), text)


def _unmask_escapes(text: str) -> str:
    return "".join(
        chr(ord(ch) - _ESCAPE_BASE) if _ESCAPE_BASE <= ord(ch) < _ESCAPE_BASE + 128 else ch
        for ch in text
    )


def parse_inline(text: str, base: frozenset[str] = frozenset()) -> list[Span]:
    text = _mask_escapes(text)
    spans: list[Span] = []
    pos = 0
    for match in INLINE_RE.finditer(text):
        if match.start() > pos:
            spans.extend(_plain_spans(text[pos : match.start()], base))
        if match.group("code") is not None:
            spans.append(Span(match.group("code"), base | {"code"}))
        elif match.group("img_url"):
            label = match.group("img_alt") or "图片"
            spans.append(
                Span(f"[{label}]", base | {"link"}, match.group("img_url"))
            )
        elif match.group("link_url"):
            label = match.group("link_text") or match.group("link_url")
            spans.append(Span(label, base | {"link"}, match.group("link_url")))
        elif match.group("b1") or match.group("b2"):
            spans.append(
                Span(match.group("b1") or match.group("b2"), base | {"bold"})
            )
        elif match.group("strike"):
            spans.append(Span(match.group("strike"), base | {"strike"}))
        else:
            spans.append(
                Span(match.group("i1") or match.group("i2"), base | {"italic"})
            )
        pos = match.end()
    if pos < len(text):
        spans.extend(_plain_spans(text[pos:], base))
    return [
        Span(_unmask_escapes(span.text), span.styles, span.url)
        for span in spans
        if span.text
    ]


# --------------------------------------------------------------------------
# 显示宽度（表格对齐）
# --------------------------------------------------------------------------
def display_width(text: str) -> int:
    return sum(
        2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text
    )


def _pad(text: str, width: int) -> str:
    gap = width - display_width(text)
    return text + " " * max(0, gap)


def strip_markers(text: str) -> str:
    """去掉简单行内标记，用于表格单元格。"""
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"[图片:\1]", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"(\*\*|__|~~|\*|_)", "", text)
    return text.strip()


# --------------------------------------------------------------------------
# Tkinter 渲染
# --------------------------------------------------------------------------
class MarkdownView:
    """把 Markdown 渲染进一个只读的 tk.Text。"""

    def __init__(
        self,
        widget,
        palette: dict[str, str],
        font_family: str = "Microsoft YaHei UI",
        mono_family: str = "Consolas",
        base_size: int = 11,
        base_dir: str | os.PathLike | None = None,
    ) -> None:
        self.widget = widget
        self.palette = palette
        self.font_family = font_family
        self.mono_family = mono_family
        self.base_size = base_size
        # 图片相对路径（assets/xxx.png）相对这个目录解析
        self.base_dir = os.fspath(base_dir) if base_dir else None
        self._style_tags: dict[tuple[frozenset[str], str | None], str] = {}
        self._link_tags: list[str] = []
        self._images: list[tuple[str, object]] = []
        self._configure_base_tags()
        widget.configure(
            wrap="word",
            padx=20,
            pady=16,
            borderwidth=0,
            highlightthickness=0,
            background=palette["bg"],
            foreground=palette["fg"],
            spacing1=0,
            spacing2=3,
            state="disabled",
            cursor="arrow",
        )

    # ---- 标签 ----
    def _configure_base_tags(self) -> None:
        w = self.widget
        bg = self.palette["bg"]
        fg = self.palette["fg"]
        w.tag_configure("heading", spacing1=12, spacing3=6, foreground=fg)
        w.tag_configure("para", spacing3=8, foreground=fg)
        w.tag_configure(
            "codeblock",
            font=(self.mono_family, self.base_size - 1),
            background=self.palette["code_bg"],
            foreground=self.palette["code_fg"],
            lmargin1=16,
            lmargin2=16,
            spacing1=6,
            spacing3=12,
            borderwidth=0,
        )
        w.tag_configure("quote", lmargin1=18, lmargin2=18, foreground=self.palette["muted"], spacing3=5)
        w.tag_configure("quotebar", foreground=self.palette["accent"], lmargin1=4)
        w.tag_configure("listbody", lmargin1=36, lmargin2=36, spacing3=4)
        w.tag_configure("marker", lmargin1=12, lmargin2=36, foreground=self.palette["muted"])
        w.tag_configure("hr", foreground=self.palette["border"], spacing1=8, spacing3=8)
        w.tag_configure(
            "table",
            font=(self.mono_family, self.base_size - 1),
            lmargin1=4,
            lmargin2=4,
            spacing1=1,
            spacing3=1,
        )
        w.tag_configure("tablehead", font=(self.mono_family, self.base_size - 1, "bold"))
        w.tag_configure("tableline", foreground=self.palette["border"])
        w.tag_configure("endpad", font=(self.font_family, 2))

    def _font(self, styles: frozenset[str]) -> tuple:
        family = self.mono_family if "code" in styles else self.font_family
        size = self.base_size
        weight_style: list[str] = []
        for key in styles:
            if key.startswith("h") and key[1:].isdigit():
                size = HEADING_SIZES.get(int(key[1:]), size)
        if "code" in styles:
            size = self.base_size - 1
        elif any(k.startswith("h") for k in styles):
            weight_style.append("bold")
        if "bold" in styles and "bold" not in weight_style:
            weight_style.append("bold")
        if "italic" in styles:
            weight_style.append("italic")
        if weight_style:
            return (family, size, " ".join(weight_style))
        return (family, size)

    def _tag(self, styles: frozenset[str], url: str | None = None) -> str:
        key = (styles, url)
        cached = self._style_tags.get(key)
        if cached:
            return cached
        name = f"mdspan{len(self._style_tags)}"
        options: dict = {"font": self._font(styles), "foreground": self.palette["fg"]}
        if "code" in styles:
            options.update(background=self.palette["code_bg"], foreground=self.palette["code_fg"])
        if "link" in styles:
            options.update(foreground=self.palette["accent"], underline=True)
        if "strike" in styles:
            options.update(overstrike=True)
        self.widget.tag_configure(name, **options)
        if url:
            self.widget.tag_bind(
                name, "<Button-1>", lambda _event, link=url: webbrowser.open(link)
            )
            self.widget.tag_bind(
                name, "<Enter>", lambda _event: self.widget.configure(cursor="hand2")
            )
            self.widget.tag_bind(
                name, "<Leave>", lambda _event: self.widget.configure(cursor="arrow")
            )
            self._link_tags.append(name)
        self._style_tags[key] = name
        return name

    def _insert_spans(self, spans: list[Span], extra: tuple[str, ...] = ()) -> None:
        for span in spans:
            tag = self._tag(span.styles, span.url)
            tags = (tag, *extra) if extra else (tag,)
            self.widget.insert("end", span.text, tags)

    # ---- 各块渲染 ----
    def render(self, md: str) -> None:
        w = self.widget
        w.configure(state="normal")
        w.delete("1.0", "end")
        # 上一轮的 PhotoImage 必须先丢引用再清空，否则旧图会一直占内存。
        self._images.clear()
        for block in parse_blocks(md):
            handler = getattr(self, f"_draw_{block.kind}", None)
            if handler:
                handler(block)
            else:  # pragma: no cover - 兜底
                w.insert("end", block.text + "\n", "para")
        w.insert("end", "\n", "endpad")
        w.configure(state="disabled")
        w.yview_moveto(0)

    def _draw_heading(self, block: Block) -> None:
        styles = frozenset({"bold", f"h{block.level}"})
        spans = parse_inline(block.text, styles)
        self._insert_spans(spans, ("heading",))
        self.widget.insert("end", "\n", "heading")

    def _draw_paragraph(self, block: Block) -> None:
        self._insert_spans(parse_inline(block.text), ("para",))
        self.widget.insert("end", "\n", "para")

    def _draw_code(self, block: Block) -> None:
        self.widget.insert("end", block.text or " ", "codeblock")
        self.widget.insert("end", "\n", "codeblock")

    def _draw_hr(self, block: Block) -> None:
        self.widget.insert("end", "─" * 56 + "\n", "hr")

    def _draw_image(self, block: Block) -> None:
        """独占一行的图片：能加载就嵌入，加载不了就显示替换文字。"""
        photo = self._load_photo(block.src)
        if photo is None:
            alt = block.text or "图片"
            self.widget.insert("end", f"[图片：{alt}]\n", "para")
        else:
            self.widget.image_create("end", image=photo, padx=4, pady=6)
            self.widget.insert("end", "\n", "para")

    def _load_photo(self, src: str):
        """把 Markdown 里的图片路径读成 Tk 可显示的 PhotoImage。

        只走内置的 tkinter.PhotoImage（支持 PNG/GIF），PNG 需要 Tk 8.6+；
        其它格式或读不到文件时返回 None，由调用方回退成文字占位。
        """
        import tkinter as tk

        if not src:
            return None
        lower = src.lower()
        if lower.startswith(("http://", "https://")):
            return None
        path = src
        if not os.path.isabs(path) and self.base_dir:
            path = os.path.join(self.base_dir, path)
        if not os.path.isfile(path):
            return None
        try:
            photo = tk.PhotoImage(master=self.widget, file=path)
        except Exception:
            return None
        self._images.append((path, photo))
        return photo

    def _draw_quote(self, block: Block) -> None:
        for line in block.text.split("\n"):
            self.widget.insert("end", "▏ ", "quotebar")
            self._insert_spans(parse_inline(line), ("quote",))
            self.widget.insert("end", "\n", "quote")

    def _draw_list(self, block: Block) -> None:
        for index, item in enumerate(block.items):
            marker = f"{block.start + index}." if block.ordered else "•"
            body = item
            task = re.match(r"^\[( |x|X)\]\s*(.*)$", body)
            if task:
                marker = "☑" if task.group(1).lower() == "x" else "☐"
                body = task.group(2)
            self.widget.insert("end", marker + " ", "marker")
            self._insert_spans(parse_inline(body), ("listbody",))
            self.widget.insert("end", "\n", "listbody")

    def _draw_table(self, block: Block) -> None:
        rows = [block.header] + block.rows
        columns = max(len(row) for row in rows)
        widths = []
        for col in range(columns):
            width = max(
                display_width(strip_markers(row[col])) if col < len(row) else 0
                for row in rows
            )
            widths.append(min(max(width, 3), 40))

        def render_row(row: list[str], header: bool) -> None:
            cells = [
                _pad(strip_markers(row[col]) if col < len(row) else "", widths[col])
                for col in range(columns)
            ]
            text = "  ".join(cells).rstrip() + "\n"
            self.widget.insert("end", text, ("table", "tablehead") if header else "table")

        render_row(block.header, True)
        self.widget.insert(
            "end", "  ".join("─" * w for w in widths) + "\n", ("table", "tableline")
        )
        for row in block.rows:
            render_row(row, False)
        self.widget.insert("end", "\n", "para")
