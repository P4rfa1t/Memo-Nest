#!/usr/bin/env python3
"""生成 assets/icon.ico（纯标准库，无需 Pillow）。

画一张便签纸：圆角黄纸 + 右上折角 + 三条文字线。
所有尺寸先按 4 倍超采样绘制，再缩小以获得平滑边缘。
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

SIZES = (256, 64, 48, 32, 16)
SS = 4  # 超采样倍数

PAPER = (255, 244, 179)
PAPER_DARK = (250, 231, 150)
EDGE = (216, 170, 60)
INK = (160, 128, 48)


def _in_round_rect(x: float, y: float, w: float, h: float, r: float) -> bool:
    if x < 0 or y < 0 or x > w or y > h:
        return False
    cx = min(max(x, r), w - r)
    cy = min(max(y, r), h - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def _draw(size: int) -> list[list[tuple[int, int, int, int]]]:
    n = size * SS
    # 画布（BGRA 预乘前的直通值，稍后统一处理）
    pixels = [[(0, 0, 0, 0)] * n for _ in range(n)]

    pad = n * 0.055
    radius = n * 0.16
    box = n - pad * 2
    # 折角三角形区域
    fold = n * 0.30
    fx = pad + box

    for y in range(n):
        for x in range(n):
            px, py = x + 0.5, y + 0.5
            inside = _in_round_rect(px - pad, py - pad, box, box, radius)
            in_fold = (px > fx - fold) and (py < pad + fold) and (
                (px - (fx - fold)) + py - pad > fold
            )
            if not inside or in_fold:
                continue
            # 折角裁掉后，靠近折线的纸面稍微加深，模拟翻折阴影
            shade = 0.0
            if px > fx - fold and py < pad + fold:
                shade = 0.18
            # 纸张内部的文字线
            inked = False
            for i, ratio in enumerate((0.34, 0.50, 0.66)):
                ly = pad + box * ratio
                lx0 = pad + box * 0.20
                lx1 = pad + box * (0.80 if i < 2 else 0.60)
                if lx0 <= px <= lx1 and abs(py - ly) <= n * 0.035:
                    inked = True
            # 外描边
            edge_test = _in_round_rect(
                px - pad, py - pad, box, box, radius
            ) and not _in_round_rect(
                px - pad - n * 0.022,
                py - pad - n * 0.022,
                box - n * 0.044,
                box - n * 0.044,
                max(radius - n * 0.022, 1),
            )
            if edge_test:
                color = EDGE
            elif inked:
                color = INK
            elif shade:
                color = tuple(int(c * (1 - shade)) for c in PAPER_DARK)
            else:
                color = PAPER
            pixels[y][x] = (*color, 255)
    return pixels


def _downsample(pixels, size: int):
    n = size * SS
    out = []
    for y in range(size):
        row = []
        for x in range(size):
            r = g = b = a = 0
            for dy in range(SS):
                for dx in range(SS):
                    pr, pg, pb, pa = pixels[y * SS + dy][x * SS + dx]
                    r += pr * pa
                    g += pg * pa
                    b += pb * pa
                    a += pa
            count = SS * SS
            if a:
                row.append((r // a, g // a, b // a, a // count))
            else:
                row.append((0, 0, 0, 0))
        out.append(row)
    return out


def _bmp_entry(size: int, rows) -> bytes:
    header = struct.pack(
        "<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0
    )
    body = bytearray()
    for y in range(size - 1, -1, -1):
        for r, g, b, a in rows[y]:
            body += bytes((b, g, r, a))
    # AND 掩码：全 0（alpha 通道已负责透明）
    mask_row = ((size + 31) // 32) * 4
    body += b"\x00" * (mask_row * size)
    return header + bytes(body)


def main() -> None:
    variants = []
    for size in SIZES:
        rows = _downsample(_draw(size), size)
        variants.append((size, _bmp_entry(size, rows)))

    out = Path(__file__).resolve().parent.parent / "assets" / "icon.ico"
    out.parent.mkdir(parents=True, exist_ok=True)

    offset = 6 + 16 * len(variants)
    directory = struct.pack("<HHH", 0, 1, len(variants))
    payload = b""
    for size, data in variants:
        directory += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset
        )
        offset += len(data)
        payload += data
    out.write_bytes(directory + payload)
    print(out)


if __name__ == "__main__":
    main()
