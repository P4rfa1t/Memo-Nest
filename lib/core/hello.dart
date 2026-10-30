/// 私密库的 Windows Hello 解锁。
///
/// 思路和 1Password / Bitwarden 一致：主密码解锁过一次之后，把**库密钥**
/// 用 DPAPI（`CryptProtectData`）加密存到 `data/vault/hello.bin`。
/// DPAPI 的密钥绑定当前 Windows 账户，别的账户、别的机器、拷走文件都解不开。
/// 之后解锁只要 Windows Hello 验证通过（PIN / 指纹 / 面容），就把库密钥取回。
///
/// 注意：这不是「用 Hello 代替主密码加密」，主密码始终是唯一的根密钥；
/// Hello 只是把已经解出来的密钥托管给系统凭据保护。所以：
/// - 改了主密码 → 库密钥不变，Hello 记录依然有效；
/// - 重置私密库 → 库密钥换新，Hello 记录必须删掉；
/// - 关掉 Hello 开关 → 立刻删掉托管记录。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'crypto.dart' as crypto;
import 'paths.dart';

/// 调用 FFI 失败时的统一异常，文案直接可以显示给用户。
class HelloError implements Exception {
  final String message;
  HelloError(this.message);
  @override
  String toString() => message;
}

// ---------------- DPAPI ----------------

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
    Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptProtectDataDart = int Function(
    Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>,
    Pointer<Void>, int, Pointer<_DataBlob>);

typedef _CryptUnprotectDataNative = Int32 Function(
    Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptUnprotectDataDart = int Function(
    Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>,
    Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);

typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

const int _cryptprotectUiForbidden = 0x1;

DynamicLibrary? _crypt32Cache;
DynamicLibrary get _crypt32 =>
    _crypt32Cache ??= DynamicLibrary.open('crypt32.dll');

DynamicLibrary? _kernel32Cache;
DynamicLibrary get _kernel32 =>
    _kernel32Cache ??= DynamicLibrary.open('kernel32.dll');

/// 用当前 Windows 账户的 DPAPI 密钥加密 [plain]。
Uint8List dpapiProtect(Uint8List plain, {String description = 'MemoNest 私密库'}) {
  final protect = _crypt32
      .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
          'CryptProtectData');
  final localFree = _kernel32
      .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

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
      throw HelloError('保存凭据失败：系统拒绝了 DPAPI 加密');
    }
    final out = Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData));
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
  final unprotect = _crypt32
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
          'CryptUnprotectData');
  final localFree = _kernel32
      .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  final input = calloc<_DataBlob>();
  final output = calloc<_DataBlob>();
  final buffer = calloc<Uint8>(blob.isEmpty ? 1 : blob.length);
  try {
    if (blob.isNotEmpty) {
      buffer.asTypedList(blob.length).setAll(0, blob);
    }
    input.ref.cbData = blob.length;
    input.ref.pbData = buffer;
    final ok = unprotect(
        input, nullptr, nullptr, nullptr, nullptr, 0, output);
    if (ok == 0) {
      throw HelloError('存储的凭据已失效，请用主密码解锁');
    }
    final out = Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData));
    localFree(output.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(input);
    calloc.free(output);
    calloc.free(buffer);
  }
}

// ---------------- Windows Hello ----------------

const MethodChannel _channel = MethodChannel('memonest/hello');

/// Windows Hello 解锁服务。上层通过 [HelloUnlock] 使用。
class HelloUnlock {
  final AppPaths paths;
  final Config config;

  HelloUnlock(this.paths, this.config);

  /// 托管文件：DPAPI 密文 + 一段用来核对「这是同一个库」的指纹。
  String get recordPath => paths.helloPath;

  /// 用户是否在设置里打开了 Hello 解锁。
  bool get enabled => config.get('vault.hello_unlock', true) == true;

  void setEnabled(bool value) {
    config.set('vault.hello_unlock', value);
    config.save();
    if (!value) forget();
  }

  /// 有没有已经托管好的凭据（开关打开 + 文件在）。
  bool get available => enabled && File(recordPath).existsSync();

  /// 系统层面 Hello 是否可用（有 PIN / 指纹 / 面容且已录入）。
  Future<bool> deviceAvailable() async {
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹系统 Hello 对话框。用户取消或验证失败都返回 false。
  Future<bool> verify({String prompt = '解锁私密笔记库'}) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('authenticate', <String, dynamic>{
        'prompt': prompt,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      throw HelloError(e.message ?? 'Windows Hello 调用失败');
    } on MissingPluginException {
      throw HelloError('当前平台不支持 Windows Hello');
    }
  }

  /// 把当前库密钥托管给系统凭据保护。
  ///
  /// 必须在库已解锁（[key] 非空）时调用。会写入 Hello 记录文件。
  void remember(Uint8List key) {
    final payload = <String, dynamic>{
      'version': 1,
      // 用它核对「这条记录对应的是哪个库」，换库或重置后对不上就忽略。
      'key_tag': crypto.keyTag(key),
      'key': crypto.b64e(key),
    };
    final blob = dpapiProtect(
        Uint8List.fromList(utf8.encode(json.encode(payload))));
    final file = File(recordPath);
    file.parent.createSync(recursive: true);
    final tmp = File('$recordPath.tmp');
    tmp.writeAsBytesSync(blob, flush: true);
    tmp.renameSync(recordPath);
  }

  /// Hello 验证通过后取回库密钥。
  ///
  /// 返回的是**新的** Uint8List；调用方拿它去 `vault.reopenWithKey()`。
  /// 记录不存在、DPAPI 解不开、指纹对不上都抛 [HelloError]。
  Future<Uint8List> retrieve({String prompt = '解锁私密笔记库'}) async {
    final file = File(recordPath);
    if (!file.existsSync()) {
      throw HelloError('还没有可用的 Windows Hello 凭据，请先用主密码解锁一次');
    }
    if (!enabled) throw HelloError('Windows Hello 解锁已关闭');
    final ok = await verify(prompt: prompt);
    if (!ok) throw HelloError('已取消');
    final plain = dpapiUnprotect(file.readAsBytesSync());
    Map<String, dynamic> payload;
    try {
      final decoded = json.decode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      payload = decoded;
    } on FormatException {
      throw HelloError('Hello 凭据已损坏，请用主密码解锁');
    }
    final keyText = payload['key'];
    if (keyText is! String || keyText.isEmpty) {
      throw HelloError('Hello 凭据已损坏，请用主密码解锁');
    }
    final key = crypto.b64d(keyText);
    final tag = payload['key_tag'];
    if (tag is String && tag.isNotEmpty && crypto.keyTag(key) != tag) {
      throw HelloError('Hello 凭据与当前私密库不匹配，请用主密码解锁');
    }
    return key;
  }

  /// 删掉托管记录（关开关、重置库、退出登录都该调）。
  void forget() {
    final file = File(recordPath);
    if (!file.existsSync()) return;
    try {
      file.deleteSync();
    } on FileSystemException {
      // 忽略：删不掉也不影响主密码解锁
    }
  }
}