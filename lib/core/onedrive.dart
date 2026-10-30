/// OneDrive 账号登录与同步（Microsoft Graph + OAuth 设备代码流程）。
///
/// 与 Python 版 `core/onedrive.py` 逐条对齐：
/// - 设备代码登录（device code flow），用户在一个网页里输码授权，全程不出密码
/// - 访问令牌按 `expires_at` 缓存，过期自动用 refresh_token 续期
/// - 上传走 `/me/drive/root:/path:/content` 的 simple upload
/// - `ensure_folder` 逐级建目录，409（已存在）当成功
/// - 私密库只上传 `.mdenc` 密文与去掉 `dpapi_key` 的 `vault.json`
///
/// 不需要安装 OneDrive 客户端，也不需要用户在本地做任何 OAuth 回调服务——
/// 设备代码流程正好适合桌面应用。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';

const String _graphBase = 'https://graph.microsoft.com/v1.0';
const String _scopes = 'offline_access Files.ReadWrite User.Read';

/// simple upload 的上限。超过要走 upload session，这里直接报错。
const int simpleUploadLimit = 250 * 1024 * 1024;

/// Graph 调用或登录过程中的可读错误。
///
/// `status` 保留 HTTP 状态码（`ensure_folder` 靠 409 判断「已存在」），
/// `payload` 保留原始 JSON，轮询时靠 `error` 字段区分 pending / slow_down。
class GraphError implements Exception {
  final String message;
  final int status;
  final Map<String, dynamic> payload;

  GraphError(this.message, {this.status = 0, Map<String, dynamic>? payload})
      : payload = payload ?? const {};

  /// 原始响应里的 `error` 字段（可能是字符串，也可能是对象）。
  String get errorCode {
    final raw = payload['error'];
    if (raw is String) return raw;
    if (raw is Map) return '${raw['code'] ?? raw['message'] ?? ''}';
    return '';
  }

  @override
  String toString() => message;
}

/// 设备代码登录的第一步：拿设备代码、用户码和验证地址。
class DeviceCodeInfo {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
  final String message;

  DeviceCodeInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
    required this.message,
  });

  factory DeviceCodeInfo.fromJson(Map<String, dynamic> json) {
    return DeviceCodeInfo(
      deviceCode: '${json['device_code'] ?? ''}',
      userCode: '${json['user_code'] ?? ''}',
      verificationUri:
          '${json['verification_uri'] ?? json['verification_url'] ?? ''}',
      expiresIn: _asInt(json['expires_in'], 900),
      interval: _asInt(json['interval'], 5),
      message: '${json['message'] ?? ''}',
    );
  }
}

class OneDriveService {
  final AppPaths paths;
  final Config config;

  OneDriveService(this.paths, this.config);

  /// 可注入的 HTTP 客户端，测试时替换成假的。
  HttpClient? httpClient;

  /// 测试注入点：把登录服务与 Graph 基址指向本地假服务器。
  ///
  /// 生产代码永远用 null（走真实微软端点）。指向的 base 会同时用于
  /// `/devicecode`、`/token`，[graphEndpointOverride] 单独给 Graph 用。
  String? endpointOverride;
  String? graphEndpointOverride;
  String? deviceCodeEndpointOverride;
  String? tokenEndpointOverride;

  // ------------------------------------------------------------------
  // HTTP 基础
  // ------------------------------------------------------------------

  String get _tenant {
    final raw = '${config.get('onedrive.tenant', 'common') ?? ''}'.trim();
    return raw.isEmpty ? 'common' : raw;
  }

  String get _authority {
    final override = endpointOverride;
    if (override != null) return override;
    return 'https://login.microsoftonline.com/$_tenant/oauth2/v2.0';
  }

  String get _deviceCodeUrl =>
      deviceCodeEndpointOverride ?? '$_authority/devicecode';

  String get _tokenUrl => tokenEndpointOverride ?? '$_authority/token';

  String get _graphRoot => graphEndpointOverride ?? _graphBase;

  String get clientId => '${config.get('onedrive.client_id', '') ?? ''}'.trim();

  /// 发一个请求，返回 (状态码, 解析后的 JSON)。
  ///
  /// 非 2xx 一律抛 [GraphError]，把服务端给的 `error_description` 摊平到
  /// 第一行——微软的报错动不动带 \r\n 和一堆文档链接，直接显示会很难看。
  Future<Map<String, dynamic>> _request(
    String method,
    String url, {
    String? token,
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
    List<int>? raw,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = httpClient ?? HttpClient();
    final ownsClient = httpClient == null;
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'MemoNest/2.0');

      // 顺序有讲究：contentLength 一设，headers 就锁死了，
      // 之后 Authorization / contentType 都改不动。
      if (token != null && token.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
      }

      if (jsonBody != null) {
        final bytes = utf8.encode(jsonEncode(jsonBody));
        request.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.contentLength = bytes.length;
        request.add(bytes);
      } else if (form != null) {
        final body = form.entries
            .map((e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        final bytes = utf8.encode(body);
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.contentLength = bytes.length;
        request.add(bytes);
      } else if (raw != null) {
        request.headers.contentType =
            ContentType('application', 'octet-stream');
        request.contentLength = raw.length;
        request.add(raw);
      } else if (method != 'GET' && method != 'DELETE') {
        // PUT/POST 没有 body 时也要显式声明长度 0，
        // 否则部分服务端会挂着等 body。
        request.contentLength = 0;
      }

      final response = await request.close().timeout(timeout);
      final text =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final status = response.statusCode;
      Map<String, dynamic> payload = const {};
      if (text.trim().isNotEmpty) {
        try {
          final decoded = json.decode(text);
          if (decoded is Map<String, dynamic>) payload = decoded;
        } on FormatException {
          payload = {'error_description': text.trim()};
        }
      }
      if (status < 200 || status >= 300) {
        // errorCode 永远从 payload['error'] 取，message 走可读文案，
        // 两者各管一头——轮询靠 errorCode 分支，用户看 message。
        throw GraphError(
          _errorText(payload, status),
          status: status,
          payload: payload,
        );
      }
      return payload;
    } on SocketException catch (e) {
      throw GraphError('网络连接失败：${e.message}');
    } on HandshakeException catch (e) {
      throw GraphError('HTTPS 握手失败：${e.message}');
    } on TimeoutException {
      throw GraphError('请求超时，请检查网络');
    } finally {
      if (ownsClient) client.close(force: true);
    }
  }

  static String _errorText(Map<String, dynamic> payload, int status) {
    final desc = payload['error_description'];
    if (desc is String && desc.trim().isNotEmpty) {
      return desc.split(RegExp(r'\r?\n')).first.trim();
    }
    final error = payload['error'];
    if (error is Map) {
      final message = error['message'] ?? error['code'];
      if (message != null && '$message'.isNotEmpty) return '$message';
    }
    if (error is String && error.isNotEmpty) return error;
    return 'HTTP $status';
  }

  // ------------------------------------------------------------------
  // 设备代码登录
  // ------------------------------------------------------------------

  /// 第一步：向微软要一组设备代码。
  ///
  /// 返回的 `userCode` 是要用户在网页里输入的那串短码，`verificationUri`
  /// 是让他打开的地址（形如 https://microsoft.com/devicelogin）。
  Future<DeviceCodeInfo> startDeviceFlow() async {
    if (clientId.isEmpty) {
      throw GraphError('请先填写 Azure 应用的客户端 ID');
    }
    final payload = await _request(
      'POST',
      _deviceCodeUrl,
      form: {'client_id': clientId, 'scope': _scopes},
    );
    final info = DeviceCodeInfo.fromJson(payload);
    if (info.deviceCode.isEmpty) {
      throw GraphError('微软没有返回设备代码，请稍后重试');
    }
    return info;
  }

  /// 第二步：轮询直到用户在浏览器里授权完成。
  ///
  /// 授权前微软会一直回 `authorization_pending`；用户切走再回来会回
  /// `slow_down`（要把间隔加长）；被拒、过期、超时都要给出明确提示。
  /// [shouldStop] 用于用户点了「取消」时提前退出。
  Future<Map<String, dynamic>> pollDeviceToken(
    DeviceCodeInfo info, {
    bool Function()? shouldStop,
  }) async {
    final deadline = DateTime.now().add(Duration(seconds: info.expiresIn));
    var wait = info.interval < 3 ? 3 : info.interval;

    while (DateTime.now().isBefore(deadline)) {
      if (shouldStop != null && shouldStop()) {
        throw GraphError('已取消登录');
      }
      await Future<void>.delayed(Duration(seconds: wait));
      if (shouldStop != null && shouldStop()) {
        throw GraphError('已取消登录');
      }
      try {
        final payload = await _request(
          'POST',
          _tokenUrl,
          form: {
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'client_id': clientId,
            'device_code': info.deviceCode,
          },
        );
        return payload;
      } on GraphError catch (e) {
        final code = e.errorCode;
        if (code == 'authorization_pending') continue;
        if (code == 'slow_down') {
          wait += 5;
          continue;
        }
        if (code == 'authorization_declined' || code == 'access_denied') {
          throw GraphError('授权被拒绝');
        }
        if (code == 'expired_token') {
          throw GraphError('登录代码已过期，请重新登录');
        }
        rethrow;
      }
    }
    throw GraphError('登录超时，请重试');
  }

  // ------------------------------------------------------------------
  // 令牌
  // ------------------------------------------------------------------

  bool get isLoggedIn =>
      '${config.get('onedrive.refresh_token', '') ?? ''}'.isNotEmpty;

  String get account => '${config.get('onedrive.account', '') ?? ''}';

  /// 保存令牌响应，并顺手把账号名拉回来。
  Future<void> saveTokens(Map<String, dynamic> payload,
      {String accountName = ''}) async {
    config.set('onedrive.access_token', '${payload['access_token'] ?? ''}');
    final expires = _asInt(payload['expires_in'], 3600);
    final expiresAt = DateTime.now()
            .add(Duration(seconds: expires > 60 ? expires - 60 : 60))
            .millisecondsSinceEpoch ~/
        1000;
    config.set('onedrive.expires_at', expiresAt);
    final refresh = payload['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      config.set('onedrive.refresh_token', refresh);
    }
    if (accountName.isNotEmpty) {
      config.set('onedrive.account', accountName);
    }
    config.save();
  }

  void logout() {
    for (final key in [
      'access_token',
      'refresh_token',
      'account',
    ]) {
      config.set('onedrive.$key', '');
    }
    config.set('onedrive.expires_at', 0);
    config.save();
  }

  /// 拿一个可用的访问令牌，过期就用 refresh_token 续。
  Future<String> accessToken({bool forceRefresh = false}) async {
    final token = '${config.get('onedrive.access_token', '') ?? ''}';
    final expiresAt = _asInt(config.get('onedrive.expires_at', 0), 0);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (token.isNotEmpty && !forceRefresh && now < expiresAt) {
      return token;
    }

    final refresh = '${config.get('onedrive.refresh_token', '') ?? ''}';
    if (refresh.isEmpty) {
      throw GraphError('尚未登录 Microsoft 账号，请先在设置里登录',
          payload: const {'error': 'no_refresh_token'});
    }
    if (clientId.isEmpty) {
      throw GraphError('缺少 Azure 应用 ID，无法刷新登录状态');
    }

    final payload = await _request(
      'POST',
      _tokenUrl,
      form: {
        'grant_type': 'refresh_token',
        'client_id': clientId,
        'refresh_token': refresh,
        'scope': _scopes,
      },
    );
    await saveTokens(payload);
    final fresh = '${payload['access_token'] ?? ''}';
    if (fresh.isEmpty) {
      throw GraphError('刷新登录状态失败，请重新登录');
    }
    return fresh;
  }

  /// 走一遍 Graph 拿账号名，顺带验证登录是否真的有效。
  Future<String> fetchAccount() async {
    final token = await accessToken(forceRefresh: true);
    final data = await _request(
      'GET',
      '$_graphRoot/me?\$select=displayName,userPrincipalName',
      token: token,
    );
    final name = '${data['displayName'] ?? data['userPrincipalName'] ?? ''}';
    if (name.isNotEmpty) {
      config.set('onedrive.account', name);
      config.save();
    }
    return name.isEmpty ? '已登录' : name;
  }

  Future<Map<String, dynamic>> _graph(
    String method,
    String path, {
    Map<String, dynamic>? jsonBody,
    List<int>? raw,
  }) async {
    final token = await accessToken();
    return _request(
      method,
      '$_graphRoot$path',
      token: token,
      jsonBody: jsonBody,
      raw: raw,
    );
  }

  // ------------------------------------------------------------------
  // 目录与文件
  // ------------------------------------------------------------------

  /// 转义路径。Graph 要求保留 `/` 作层级分隔，其余逐段百分号编码。
  static String _quote(String path) {
    final trimmed = path.replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
  }

  /// 逐级建目录。已经存在（409）不算错，其他错误往上抛。
  Future<void> ensureFolder(String folder) async {
    var current = '';
    for (final part in folder.split('/').where((s) => s.isNotEmpty)) {
      final parent = current.isEmpty
          ? '/me/drive/root/children'
          : '/me/drive/root:/${_quote(current)}:/children';
      try {
        await _graph(
          'POST',
          parent,
          jsonBody: {
            'name': part,
            'folder': <String, dynamic>{},
            '@microsoft.graph.conflictBehavior': 'fail',
          },
        );
      } on GraphError catch (e) {
        if (e.status != 409) rethrow;
      }
      current = current.isEmpty ? part : '$current/$part';
    }
  }

  /// 上传一个文件到指定目录（目录会自动建）。
  Future<void> uploadFile(String localPath, String folder,
      {String? name}) async {
    final file = File(localPath);
    if (!file.existsSync()) {
      throw GraphError('找不到要上传的文件：$localPath');
    }
    final data = file.readAsBytesSync();
    if (data.length > simpleUploadLimit) {
      throw GraphError('${p.basename(localPath)} 超过 250MB，暂不支持上传');
    }
    await ensureFolder(folder);
    final base = name ?? p.basename(localPath);
    final target = '${folder.replaceAll(RegExp(r'^/+|/+$'), '')}/$base'
        .replaceAll(RegExp(r'^/+'), '');
    await _graph('PUT', '/me/drive/root:/${_quote(target)}:/content',
        raw: data);
  }

  /// 列目录里的条目。返回 `[{id, name, lastModifiedDateTime}, ...]`。
  Future<List<Map<String, dynamic>>> listChildren(String folder) async {
    final trimmed = folder.replaceAll(RegExp(r'^/+|/+$'), '');
    final path = trimmed.isEmpty
        ? '/me/drive/root/children'
        : '/me/drive/root:/${_quote(trimmed)}:/children';
    final data = await _graph(
      'GET',
      '$path?\$select=id,name,lastModifiedDateTime&\$top=200',
    );
    final value = data['value'];
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> deleteItem(String itemId) async {
    await _graph('DELETE', '/me/drive/items/${Uri.encodeComponent(itemId)}');
  }

  // ------------------------------------------------------------------
  // 同步
  // ------------------------------------------------------------------

  /// 把本地内容推到云端。返回一行可读结果。
  ///
  /// 流程与 Python 版 `sync()` 一致：
  /// 1. 建好子目录
  /// 2. 开了「镜像明文笔记」时，逐篇上传 .md，删掉云端多余的同名文件
  /// 3. 私密库上传 `.mdenc` 密文与去掉 `dpapi_key` 的 `vault.json`
  /// 4. 上传本次 zip 快照，按 `keep_backups` 清理旧的
  String get subfolder {
    final raw = '${config.get('onedrive.subfolder', 'MemoNest备份') ?? ''}';
    final trimmed = raw.replaceAll(RegExp(r'^/+|/+$'), '').trim();
    return trimmed.isEmpty ? 'MemoNest备份' : trimmed;
  }

  Future<String> sync({File? snapshot}) async {
    // 真正的前置条件只有「能拿到访问令牌」：有缓存令牌、或者有
    // refresh_token 能续期都算数。accessToken() 自己会把两种情况分清楚。
    if (clientId.isEmpty &&
        !isLoggedIn &&
        '${config.get('onedrive.access_token', '') ?? ''}'.isEmpty) {
      throw GraphError('尚未配置 OneDrive 账号，请先在设置里登录');
    }
    final folder = subfolder;
    await ensureFolder(folder);

    var uploaded = 0;

    if (config.get('onedrive.mirror_notes', true) == true) {
      final notesFolder = '$folder/notes';
      await ensureFolder(notesFolder);
      final current = <String>{};
      final notesDir = Directory(paths.notesDir);
      if (notesDir.existsSync()) {
        final files = notesDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in files) {
          await uploadFile(file.path, notesFolder);
          current.add(p.basename(file.path));
          uploaded++;
        }
      }
      // 云端已经不存在的笔记要跟着删，否则越堆越多
      for (final item in await listChildren(notesFolder)) {
        final name = '${item['name'] ?? ''}';
        final id = '${item['id'] ?? ''}';
        if (name.endsWith('.md') && !current.contains(name) && id.isNotEmpty) {
          await deleteItem(id);
        }
      }

      final index = File(paths.indexPath);
      if (index.existsSync()) {
        await uploadFile(index.path, folder);
      }

      // 私密库：只上传密文，密钥包裹在 vault.json 里，dpapi_key 留在本机
      final itemsDir = Directory(paths.vaultItemsDir);
      if (itemsDir.existsSync()) {
        final itemsFolder = '$folder/vault/items';
        await ensureFolder(itemsFolder);
        final encrypted = <String>{};
        final files = itemsDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.mdenc'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final file in files) {
          await uploadFile(file.path, itemsFolder);
          encrypted.add(p.basename(file.path));
          uploaded++;
        }
        for (final item in await listChildren(itemsFolder)) {
          final name = '${item['name'] ?? ''}';
          final id = '${item['id'] ?? ''}';
          if (name.endsWith('.mdenc') &&
              !encrypted.contains(name) &&
              id.isNotEmpty) {
            await deleteItem(id);
          }
        }

        final meta = File(paths.vaultMetaPath);
        if (meta.existsSync()) {
          Map<String, dynamic> payload = {};
          try {
            final decoded = json.decode(meta.readAsStringSync());
            if (decoded is Map<String, dynamic>) payload = decoded;
          } on FormatException {
            payload = {};
          } on FileSystemException {
            payload = {};
          }
          payload.remove('dpapi_key');
          final target = '$folder/vault/vault.json';
          await _graph(
            'PUT',
            '/me/drive/root:/${_quote(target)}:/content',
            raw: utf8
                .encode(const JsonEncoder.withIndent('  ').convert(payload)),
          );
        }
      }
    }

    if (snapshot != null && snapshot.existsSync()) {
      await uploadFile(snapshot.path, folder);
      final keep = _asInt(config.get('onedrive.keep_backups', 30), 30);
      await _prune(folder, keep);
    }

    final who = account.isEmpty ? 'Microsoft 账号' : account;
    return '已用 $who 上传 $uploaded 篇笔记';
  }

  Future<void> _prune(String folder, int keep) async {
    if (keep <= 0) return;
    final backups = (await listChildren(folder)).where((item) {
      final name = '${item['name'] ?? ''}';
      return name.startsWith('memo-backup-') && name.endsWith('.zip');
    }).toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    if (backups.length <= keep) return;
    for (final stale in backups.take(backups.length - keep)) {
      final id = '${stale['id'] ?? ''}';
      if (id.isEmpty) continue;
      try {
        await deleteItem(id);
      } on GraphError {
        // 删不掉就算了，下次同步再试
      }
    }
  }

  /// 完整登录流程：拿设备代码 → 轮询 → 存令牌 → 拉账号名。
  ///
  /// [onCode] 在拿到设备代码时回调，用来把「去哪个网页输哪串码」显示给用户。
  /// [shouldStop] 供用户取消。
  Future<String> loginDeviceFlow({
    void Function(DeviceCodeInfo info)? onCode,
    bool Function()? shouldStop,
  }) async {
    final info = await startDeviceFlow();
    onCode?.call(info);
    final payload = await pollDeviceToken(info, shouldStop: shouldStop);
    await saveTokens(payload);
    try {
      return await fetchAccount();
    } on GraphError {
      // 拉不到名字不影响已经到手的令牌
      return '已登录';
    }
  }
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}
