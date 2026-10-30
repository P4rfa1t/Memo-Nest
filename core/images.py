"""把剪贴板位图存成便签目录里的 PNG，供 Markdown 预览引用。"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

ASSETS_DIRNAME = "assets"


def _png_chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def png_from_bgr(width: int, height: int, bpp: int, data: bytes) -> bytes:
    """把上到下的 BGR/BGRX 原始行数据编码成 PNG（8 位 RGB，不透明）。"""
    if width <= 0 or height <= 0:
        raise ValueError("图片尺寸无效")
    stride_out = width * 3
    rows = bytearray()
    for y in range(height):
        start = y * width * (bpp // 8)
        line = bytearray(stride_out)
        for x in range(width):
            si = start + x * (bpp // 8)
            di = x * 3
            line[di] = data[si + 2]
            line[di + 1] = data[si + 1]
            line[di + 2] = data[si]
        rows.append(0)  # filter type: none
        rows.extend(line)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", header)
        + _png_chunk(b"IDAT", zlib.compress(bytes(rows), 6))
        + _png_chunk(b"IEND", b"")
    )


def save_clipboard_image(
    bitmap: tuple[int, int, int, bytes],
    notes_dir: Path,
    stem: str,
) -> tuple[str, Path]:
    """写出 PNG，返回 (相对 Markdown 路径, 绝对路径)。

    路径用正斜杠，保证 Markdown 在各处解析一致；文件名带短哈希避免同名覆盖。
    """
    width, height, bpp, data = bitmap
    payload = png_from_bgr(width, height, bpp, data)
    digest = zlib.crc32(payload) & 0xFFFFFFFF
    assets = Path(notes_dir) / ASSETS_DIRNAME
    assets.mkdir(parents=True, exist_ok=True)
    name = f"{stem}-{digest:08x}.png"
    target = assets / name
    if not target.exists():
        target.write_bytes(payload)
    return f"{ASSETS_DIRNAME}/{name}", target


def note_assets_dir(notes_dir: Path) -> Path:
    path = Path(notes_dir) / ASSETS_DIRNAME
    path.mkdir(parents=True, exist_ok=True)
    return path