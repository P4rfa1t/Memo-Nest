/// Windows DPAPI：把一段密钥材料绑到当前 Windows 账户上加密。
///
/// 只有 Windows 会调用；其它平台编译得过（`dart:ffi` 到处都有），
/// 但 `DynamicLibrary.open('crypt32.dll')` 是懒加载的，不会在启动时炸。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptProtectDataDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);

typedef _CryptUnprotectDataNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptUnprotectDataDart = int Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

const int _cryptprotectUiForbidden = 0x1;

DynamicLibrary? _crypt32Cache;
DynamicLibrary get _crypt32 =>
    _crypt32Cache ??= DynamicLibrary.open('crypt32.dll');

DynamicLibrary? _kernel32Cache;
DynamicLibrary get _kernel32 =>
    _kernel32Cache ??= DynamicLibrary.open('kernel32.dll');

/// DPAPI 失败。文案可以直接显示给用户。
class DpapiError implements Exception {
  final String message;
  DpapiError(this.message);
  @override
  String toString() => message;
}

/// 用当前 Windows 账户的 DPAPI 密钥加密 [plain]。
Uint8List dpapiProtect(Uint8List plain, {String description = 'MemoNest 私密库'}) {
  final protect =
      _crypt32.lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
          'CryptProtectData');
  final localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final buffer = calloc<Uint8>(plain.isEmpty ? 1 : plain.length);
  final desc = description.toNativeUtf16();
  try {
    if (plain.isNotEmpty) {
      buffer.asTypedList(plain.length).setAll(0, plain);
    }
    input.ref.cbData = plain.length;
    input.ref.pbData = buffer;
    final ok = protect(input, desc, nullptr, nullptr, nullptr,
        _cryptprotectUiForbidden, output);
    if (ok == 0) {
      throw DpapiError('保存凭据失败：系统拒绝了 DPAPI 加密');
    }
    final out =
        Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
    localFree(output.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(input);
    calloc.free(output);
    calloc.free(buffer);
    calloc.free(desc);
  }
}

/// 用当前 Windows 账户的 DPAPI 密钥解密 [blob]。
Uint8List dpapiUnprotect(Uint8List blob) {
  final unprotect = _crypt32.lookupFunction<_CryptUnprotectDataNative,
      _CryptUnprotectDataDart>('CryptUnprotectData');
  final localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final buffer = calloc<Uint8>(blob.isEmpty ? 1 : blob.length);
  try {
    if (blob.isNotEmpty) {
      buffer.asTypedList(blob.length).setAll(0, blob);
    }
    input.ref.cbData = blob.length;
    input.ref.pbData = buffer;
    final ok = unprotect(input, nullptr, nullptr, nullptr, nullptr, 0, output);
    if (ok == 0) {
      throw DpapiError('存储的凭据已失效，请用主密码解锁');
    }
    final out =
        Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
    localFree(output.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(input);
    calloc.free(output);
    calloc.free(buffer);
  }
}
