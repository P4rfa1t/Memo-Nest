/// 加密原语：scrypt 口令派生 + AES-256-GCM 认证加密。
///
/// 与 Python 版 `core/crypto.py` **逐字节兼容**：
/// - scrypt 参数 N=2^15, r=8, p=1, dklen=32, salt 16 字节
/// - 密文布局 `nonce(12) || ciphertext || tag(16)`（GCM 的 tag 追加在密文尾部）
/// - base64 用标准字母表
///
/// 这两条约束决定了 Flutter 版能直接读写 Python 版生成的 vault.json
/// 与 items/*.mdenc，用户换版本不会丢私密笔记。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const int scryptN = 1 << 15;
const int scryptR = 8;
const int scryptP = 1;
const int saltBytes = 16;
const int keyBytes = 32;
const int nonceBytes = 12;
const int tagBytes = 16;

final Uint8List aadMeta = ascii.encode('memonest-vault-v1');
final Uint8List aadNote = ascii.encode('memonest-note-v1');
final Uint8List aadTrash = ascii.encode('memonest-trash-v1');

class CryptoError implements Exception {
  final String message;
  CryptoError(this.message);
  @override
  String toString() => message;
}

/// scrypt 派生。默认参数与 Python 版一致（约 32MB 内存、0.1~0.3 秒）。
///
/// 纯 Dart 实现比 OpenSSL 慢一个量级（N=2^15 实测 1~3 秒），
/// 所以调用方应当在 isolate 里跑，别卡住 UI 帧。
Uint8List derive(
  String password,
  Uint8List salt, {
  int n = scryptN,
  int r = scryptR,
  int p = scryptP,
}) {
  if (password.isEmpty) {
    throw CryptoError('口令不能为空');
  }
  final params = ScryptParameters(
    max(1 << 12, n),
    max(1, r),
    max(1, p),
    keyBytes,
    salt,
  );
  final scrypt = Scrypt()..init(params);
  return scrypt.process(Uint8List.fromList(utf8.encode(password)));
}

final Random _rng = Random.secure();

Uint8List newSalt() {
  final out = Uint8List(saltBytes);
  for (var i = 0; i < saltBytes; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

Uint8List newKey() {
  final out = Uint8List(keyBytes);
  for (var i = 0; i < keyBytes; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// AES-256-GCM 加密，返回 `nonce || ciphertext || tag`。
Uint8List encrypt(Uint8List key, Uint8List plaintext, Uint8List aad) {
  final nonce = Uint8List(nonceBytes);
  for (var i = 0; i < nonceBytes; i++) {
    nonce[i] = _rng.nextInt(256);
  }
  final gcm = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(KeyParameter(key), 128, nonce, aad),
    );
  final cipherText = gcm.process(plaintext);
  final out = Uint8List(nonceBytes + cipherText.length);
  out.setRange(0, nonceBytes, nonce);
  out.setRange(nonceBytes, out.length, cipherText);
  return out;
}

/// AES-256-GCM 解密，入参为 `nonce || ciphertext || tag`。
Uint8List decrypt(Uint8List key, Uint8List blob, Uint8List aad) {
  if (blob.length <= nonceBytes) {
    throw CryptoError('密文长度异常');
  }
  final nonce = Uint8List.sublistView(blob, 0, nonceBytes);
  final body = Uint8List.sublistView(blob, nonceBytes);
  final gcm = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(KeyParameter(key), 128, nonce, aad),
    );
  try {
    return gcm.process(body);
  } on InvalidCipherTextException {
    throw CryptoError('口令不正确，或数据已被修改');
  }
}

String b64e(Uint8List data) => base64.encode(data);

Uint8List b64d(String text) => Uint8List.fromList(base64.decode(text));

/// 库密钥指纹，与 Python `Vault._key_tag` 完全一致。
String keyTag(Uint8List key) {
  final digest = SHA256Digest().process(
    Uint8List.fromList([...ascii.encode('memonest-key-tag'), ...key]),
  );
  final hex = digest
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return hex.substring(0, 16);
}

/// 拼 AAD：`aad_note || note_id`，与 Python `AAD_NOTE + note.id.encode()` 一致。
Uint8List noteAad(String noteId) =>
    Uint8List.fromList([...aadNote, ...utf8.encode(noteId)]);
