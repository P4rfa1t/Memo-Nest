/// 纯 Dart 的 PNG 编码（8 位 RGB，filter 0，zlib 存储块）。
///
/// 只依赖 `dart:typed_data`，三个平台通用——Windows 用它把剪贴板里的
/// CF_DIB 位图变成 PNG，Android 用它把相册/相机拿到的像素写成附件。
library;

import 'dart:typed_data';

/// 把自上而下的 BGR / BGRX / BGR A 行数据编码成 PNG。
///
/// [pixels] 每行按 `((width * bitCount + 31) ~/ 32) * 4` 字节对齐，
/// 和 Win32 的 DIB 约定一致。
Uint8List encodeBgrPng({
  required int width,
  required int height,
  required int bitCount,
  required Uint8List pixels,
}) {
  final bpp = bitCount ~/ 8;
  final stride = ((width * bitCount + 31) ~/ 32) * 4;

  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: None
    final rowStart = y * stride;
    for (var x = 0; x < width; x++) {
      final i = rowStart + x * bpp;
      raw.addByte(pixels[i + 2]); // R
      raw.addByte(pixels[i + 1]); // G
      raw.addByte(pixels[i]); // B
    }
  }
  final compressed = _zlibStore(raw.takeBytes());

  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_u32be(width))
    ..add(_u32be(height))
    ..add([8, 2, 0, 0, 0]); // 位深 8、颜色类型 2(RGB)
  _chunk(out, 'IHDR', ihdr.takeBytes());
  _chunk(out, 'IDAT', compressed);
  _chunk(out, 'IEND', Uint8List(0));
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String tag, List<int> data) {
  final body = <int>[...tag.codeUnits, ...data];
  out.add(_u32be(data.length));
  out.add(body);
  out.add(_u32be(_crc32(body)));
}

List<int> _u32be(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

/// 只做存储（不压缩）的 zlib 流：每个块头 + 原始字节 + Adler-32。
///
/// 截图动辄几百 KB，压不动也认了——Dart 标准库没有暴露 deflate，
/// 引入 `archive` 包只为一个函数不划算。
Uint8List _zlibStore(Uint8List data) {
  final out = BytesBuilder();
  out.addByte(0x78); // CMF: deflate, 32K window
  out.addByte(0x01); // FLG: 无字典、最快
  const maxBlock = 65535;
  var offset = 0;
  while (offset < data.length) {
    final size = (data.length - offset).clamp(0, maxBlock);
    final last = offset + size >= data.length ? 1 : 0;
    out.addByte(last);
    out.addByte(size & 0xff);
    out.addByte((size >> 8) & 0xff);
    out.addByte((~size) & 0xff);
    out.addByte(((~size) >> 8) & 0xff);
    out.add(data.sublist(offset, offset + size));
    offset += size;
  }
  if (data.isEmpty) {
    out.add([1, 0, 0, 0xff, 0xff]);
  }
  final adler = _adler32(data);
  out.add(_u32be(adler));
  return out.takeBytes();
}

int _adler32(Uint8List data) {
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}
