/// 从 Windows 剪贴板读 CF_DIB / CF_DIBV5 位图。
///
/// Flutter 的 `Clipboard` 只支持纯文本，截图粘贴必须自己走 Win32。
/// 这里用 dart:ffi 直接调 user32/kernel32，不引入任何插件。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'png.dart';

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
  late final _CloseClipboardD closeClipboard = user32
      .lookupFunction<_CloseClipboardC, _CloseClipboardD>('CloseClipboard');
  late final _IsClipboardFormatAvailableD isFormatAvailable =
      user32.lookupFunction<_IsClipboardFormatAvailableC,
          _IsClipboardFormatAvailableD>(
    'IsClipboardFormatAvailable',
  );
  late final _GetClipboardDataD getClipboardData =
      user32.lookupFunction<_GetClipboardDataC, _GetClipboardDataD>(
          'GetClipboardData');
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
    return api.isFormatAvailable(_cfDib) != 0 ||
        api.isFormatAvailable(_cfDibV5) != 0;
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

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// 把 BGR/BGRX 位图编码成 PNG。
///
/// 实现在 `png.dart` 里（纯 Dart，三个平台共用）；这里保留这个签名是因为
/// Windows 剪贴板位图就是 DIB 布局，直接转过去即可。
Uint8List encodePng(ClipboardBitmap bitmap) => encodeBgrPng(
      width: bitmap.width,
      height: bitmap.height,
      bitCount: bitmap.bitCount,
      pixels: bitmap.pixels,
    );
