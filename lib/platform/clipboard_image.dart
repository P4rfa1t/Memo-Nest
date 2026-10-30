/// 从 Windows 剪贴板读 CF_DIB / CF_DIBV5 位图。
///
/// Flutter 的 `Clipboard` 只支持纯文本，截图粘贴必须自己走 Win32。
/// 这里用 dart:ffi 直接调 user32/kernel32，不引入任何插件。
library;

import 'dart:ffi';
import 'dart:typed_data';

const int _cfDib = 8;
const int _cfDibV5 = 17;

typedef _OpenClipboardC = Int32 Function(IntPtr);
typedef _OpenClipboardD = int Function(int);

typedef _CloseClipboardC = Int32 Function();
typedef _CloseClipboardD = int Function();

typedef _IsClipboardFormatAvailableC = Int32 Function(Uint32);
typedef _IsClipboardFormatAvailableD = int Function(int);

typedef _GetClipboardDataC = IntPtr Function(Uint32);
typedef _GetClipboardDataD = int Function(int);

typedef _GlobalLockC = Pointer<Uint8> Function(IntPtr);
typedef _GlobalLockD = Pointer<Uint8> Function(int);

typedef _GlobalUnlockC = Int32 Function(IntPtr);
typedef _GlobalUnlockD = int Function(int);

typedef _GlobalSizeC = IntPtr Function(IntPtr);
typedef _GlobalSizeD = int Function(int);

class ClipboardBitmap {
  final int width;
  final int height;
  final int bitCount;

  /// 自上而下的 BGR / BGRX 原始行数据。
  final Uint8List pixels;

  ClipboardBitmap(this.width, this.height, this.bitCount, this.pixels);
}

class _Win32 {
  final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
  final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');

  late final _OpenClipboardD openClipboard =
      user32.lookupFunction<_OpenClipboardC, _OpenClipboardD>('OpenClipboard');
  late final _CloseClipboardD closeClipboard =
      user32.lookupFunction<_CloseClipboardC, _CloseClipboardD>('CloseClipboard');
  late final _IsClipboardFormatAvailableD isFormatAvailable =
      user32.lookupFunction<_IsClipboardFormatAvailableC, _IsClipboardFormatAvailableD>(
    'IsClipboardFormatAvailable',
  );
  late final _GetClipboardDataD getClipboardData =
      user32.lookupFunction<_GetClipboardDataC, _GetClipboardDataD>('GetClipboardData');
  late final _GlobalLockD globalLock =
      kernel32.lookupFunction<_GlobalLockC, _GlobalLockD>('GlobalLock');
  late final _GlobalUnlockD globalUnlock =
      kernel32.lookupFunction<_GlobalUnlockC, _GlobalUnlockD>('GlobalUnlock');
  late final _GlobalSizeD globalSize =
      kernel32.lookupFunction<_GlobalSizeC, _GlobalSizeD>('GlobalSize');
}

_Win32? _win32;

_Win32 get _api => _win32 ??= _Win32();

/// 剪贴板里是否有位图。
bool clipboardHasImage() {
  try {
    final api = _api;
    return api.isFormatAvailable(_cfDib) != 0 || api.isFormatAvailable(_cfDibV5) != 0;
  } on Object {
    return false;
  }
}

/// 读取剪贴板位图；没有或格式不支持时返回 null。
ClipboardBitmap? readClipboardBitmap() {
  final api = _api;
  final format = api.isFormatAvailable(_cfDibV5) != 0
      ? _cfDibV5
      : (api.isFormatAvailable(_cfDib) != 0 ? _cfDib : 0);
  if (format == 0) return null;
  if (api.openClipboard(0) == 0) return null;

  try {
    final handle = api.getClipboardData(format);
    if (handle == 0) return null;

    final pointer = api.globalLock(handle);
    if (pointer == nullptr) return null;
    try {
      final size = api.globalSize(handle);
      if (size < 40) return null;
      final bytes = pointer.asTypedList(size);

      // BITMAPINFOHEADER
      final headerSize = _i32(bytes, 0);
      final width = _i32(bytes, 4);
      final rawHeight = _i32(bytes, 8);
      final bitCount = _u16(bytes, 14);
      final compression = _i32(bytes, 16);
      if (headerSize < 40 || width <= 0 || rawHeight == 0) return null;
      if (bitCount != 24 && bitCount != 32) return null;
      // BI_RGB(0) 与 BI_BITFIELDS(3) 都能按 24/32 位解
      if (compression != 0 && compression != 3) return null;

      final bottomUp = rawHeight > 0;
      final height = rawHeight.abs();
      final stride = ((width * bitCount + 31) ~/ 32) * 4;
      final offset = 40; // 24/32 位不需要调色板
      final need = offset + stride * height;
      if (bytes.length < need) return null;

      final pixels = Uint8List(stride * height);
      if (bottomUp) {
        for (var row = 0; row < height; row++) {
          final src = offset + (height - 1 - row) * stride;
          pixels.setRange(row * stride, (row + 1) * stride, bytes, src);
        }
      } else {
        pixels.setRange(0, stride * height, bytes, offset);
      }
      return ClipboardBitmap(width, height, bitCount, pixels);
    } finally {
      api.globalUnlock(handle);
    }
  } finally {
    api.closeClipboard();
  }
}

int _i32(Uint8List bytes, int offset) {
  final v = bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  return v & 0x80000000 != 0 ? v - 0x100000000 : v;
}

int _u16(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8);

/// 把 BGR/BGRX 位图编码成 PNG（8 位 RGB，filter 0，zlib 压缩）。
Uint8List encodePng(ClipboardBitmap bitmap) {
  final width = bitmap.width;
  final height = bitmap.height;
  final bpp = bitmap.bitCount ~/ 8;
  final stride = ((width * bitmap.bitCount + 31) ~/ 32) * 4;

  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: None
    final rowStart = y * stride;
    for (var x = 0; x < width; x++) {
      final i = rowStart + x * bpp;
      raw.addByte(bitmap.pixels[i + 2]); // R
      raw.addByte(bitmap.pixels[i + 1]); // G
      raw.addByte(bitmap.pixels[i]); // B
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

List<int> _u32be(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

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

/// 纯 Dart 的 zlib 容器（deflate store 模式，不压缩）。
///
/// 图片本身已经是压缩过的格式，再压一遍收益很小；
/// 用 store 换来零依赖与可预测的速度。
Uint8List _zlibStore(Uint8List data) {
  final out = BytesBuilder();
  out.add([0x78, 0x01]); // zlib header，无预设字典
  var offset = 0;
  while (offset < data.length) {
    final block = (data.length - offset).clamp(0, 65535);
    final last = offset + block >= data.length ? 1 : 0;
    out.addByte(last);
    out.addByte(block & 0xff);
    out.addByte((block >> 8) & 0xff);
    out.addByte(~block & 0xff);
    out.addByte((~block >> 8) & 0xff);
    out.add(data.sublist(offset, offset + block));
    offset += block;
  }
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  out.add(_u32be((b << 16) | a));
  return out.takeBytes();
}
