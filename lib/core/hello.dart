/// 私密库的系统凭据解锁（Windows Hello / Android 生物识别）。
///
/// 思路和 1Password / Bitwarden 一致：主密码解锁过一次之后，把**库密钥**
/// 用平台密钥库加密存到 `data/vault/hello.bin`——
/// Windows 走 DPAPI（绑定当前账户），Android 走 Keystore（绑定本机 Keystore）。
///
/// 注意：这不是「用生物识别代替主密码加密」，主密码始终是唯一的根密钥；
/// 系统验证只是把已经解出来的密钥托管给系统凭据保护。所以：
/// - 改了主密码 → 库密钥不变，托管记录依然有效；
/// - 重置私密库 → 库密钥换新，托管记录必须删掉；
/// - 关掉开关 → 立刻删掉托管记录。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../platform/host.dart';
import 'crypto.dart' as crypto;
import 'paths.dart';

/// 调用系统验证失败时的统一异常，文案直接可以显示给用户。
class HelloError implements Exception {
  final String message;
  HelloError(this.message);
  @override
  String toString() => message;
}

/// 系统凭据解锁服务。上层通过 [HelloUnlock] 使用。
class HelloUnlock {
  final AppPaths paths;
  final Config config;
  final Host host;

  HelloUnlock(this.paths, this.config, this.host);

  /// 托管文件：平台密钥库密文 + 一段用来核对「这是同一个库」的指纹。
  String get recordPath => paths.helloPath;

  /// 当前平台是否具备托管能力（决定设置里那个开关是否显示）。
  bool get supported => host.secretSupported && host.deviceAuthSupported;

  /// 用户是否在设置里打开了这个功能。
  bool get enabled => config.get('vault.hello_unlock', true) == true;

  Future<void> setEnabled(bool value) async {
    config.set('vault.hello_unlock', value);
    config.save();
    if (!value) await forget();
  }

  /// 有没有已经托管好的凭据（开关打开 + 文件在）。
  bool get available => enabled && File(recordPath).existsSync();

  /// 系统层面是否可用（有 PIN / 指纹 / 面容且已录入）。
  Future<bool> deviceAvailable() async {
    if (!host.deviceAuthSupported) return false;
    try {
      return await host.deviceAuthAvailable();
    } on HostError {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 弹系统验证对话框。用户取消或验证失败都返回 false。
  Future<bool> verify({String prompt = '解锁私密笔记库'}) async {
    try {
      return await host.deviceAuthVerify(prompt: prompt);
    } on HostError catch (e) {
      throw HelloError(e.message);
    } on MissingPluginException {
      throw HelloError('当前平台不支持系统凭据验证');
    }
  }

  /// 把当前库密钥托管给系统凭据保护。
  ///
  /// 必须在库已解锁（[key] 非空）时调用。会写入托管记录文件。
  Future<void> remember(Uint8List key) async {
    final payload = <String, dynamic>{
      'version': 1,
      // 用它核对「这条记录对应的是哪个库」，换库或重置后对不上就忽略。
      'key_tag': crypto.keyTag(key),
      'key': crypto.b64e(key),
    };
    final blob = await host.protectSecret(
      Uint8List.fromList(utf8.encode(json.encode(payload))),
      description: 'MemoNest 私密库',
    );
    final file = File(recordPath);
    file.parent.createSync(recursive: true);
    final tmp = File('$recordPath.tmp');
    tmp.writeAsBytesSync(blob, flush: true);
    tmp.renameSync(recordPath);
  }

  /// 系统验证 + 取回库密钥。用户取消抛 [HelloError]('已取消')。
  Future<Uint8List> retrieve({String prompt = '解锁私密笔记库'}) async {
    if (!enabled) {
      throw HelloError('系统凭据解锁已关闭，请用主密码解锁');
    }
    final file = File(recordPath);
    if (!file.existsSync()) {
      throw HelloError('还没有可用的系统凭据，请先用主密码解锁一次');
    }
    final ok = await verify(prompt: prompt);
    if (!ok) throw HelloError('已取消');

    Uint8List plain;
    try {
      plain = await host.unprotectSecret(file.readAsBytesSync());
    } on HostError catch (e) {
      throw HelloError(e.message);
    } on FileSystemException {
      throw HelloError('读取托管凭据失败，请用主密码解锁');
    }

    Map<String, dynamic> payload;
    try {
      final decoded = json.decode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic>) {
        throw HelloError('托管凭据格式不对，请用主密码解锁');
      }
      payload = decoded;
    } on FormatException {
      throw HelloError('托管凭据已损坏，请用主密码解锁');
    }

    final encoded = payload['key'];
    if (encoded is! String) {
      throw HelloError('托管凭据已损坏，请用主密码解锁');
    }
    final key = crypto.b64d(encoded);
    final tag = payload['key_tag'];
    if (tag is String && tag != crypto.keyTag(key)) {
      throw HelloError('系统凭据与当前私密库不匹配，请用主密码解锁');
    }
    return key;
  }

  /// 删掉托管记录（关开关、重置私密库时调用）。
  Future<void> forget() async {
    final file = File(recordPath);
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // 删不掉也不影响主流程，下次会覆盖
    }
  }
}
