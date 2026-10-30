/// OneDrive 同步（Microsoft Graph + OAuth PKCE）。
///
/// 设计目标是对齐 Obsidian Remotely Save 的 OneDrive 体验：
/// - **授权码 + PKCE + 本地回环回调**，点一下「连接」直接开浏览器，
///   登录完成自动回到应用，不用手抄设备码。设备代码流程作为兜底保留。
/// - **App Folder 模式**：用 `Files.ReadWrite.AppFolder` 这个最小权限，
///   只拿到本应用自己的私有目录（`/me/drive/special/approot`），
///   动不到用户 OneDrive 里其它任何文件。也可以切回全盘根目录。
/// - **逐文件增量同步**：按 `size + lastModifiedDateTime` 与上一次同步
///   记在本地 `onedrive-sync.json` 的基线比对，只传有变化的文件；
///   远端我们删掉的本地文件也会同步删除。不再每次全量重传。
/// - **双语路径不冲突**：所有远端路径都逐段百分号编码。
///
/// 私密库只上传 `.mdenc` 密文与去掉 `dpapi_key` 的 `vault.json`，
/// 明文与 DPAPI 密钥永远不出本机。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'paths.dart';

const String _graphBase = 'https://graph.microsoft.com/v1.0';

/// App Folder 模式（推荐）：只能读写本应用自己的私有目录。
const String _scopeAppFolder =
    'offline_access Files.ReadWrite.AppFolder User.Read';

/// 全盘模式：能读写用户 OneDrive 里任意文件，权限大得多。
const String _scopeFull = 'offline_access Files.ReadWrite User.Read';

/// simple upload 的上限，超过要走 upload session。
const int simpleUploadLimit = 250 * 1024 * 1024;

/// Graph 单个文件硬上限 250GB，超过就没法传了。
const int maxUploadBytes = 250 * 1024 * 1024 * 1024;

/// 上传上限的当前值。默认就是上面两个常量；测试可以压到几十字节来
/// 走分块/超限分支，不用真造 250MB 的文件（NTFS 稀疏文件会被当成超额
/// 分配，`truncateSync` 直接 errno 112）。
int _simpleLimit = simpleUploadLimit;
int _maxLimit = maxUploadBytes;

/// 在 [body] 执行期间临时替换上传上限，结束后无条件还原。
Future<T> withUploadLimits<T>({
  int? simpleUploadLimit,
  int? maxUploadBytes,
  required Future<T> Function() body,
}) async {
  final oldSimple = _simpleLimit;
  final oldMax = _maxLimit;
  if (simpleUploadLimit != null) _simpleLimit = simpleUploadLimit;
  if (maxUploadBytes != null) _maxLimit = maxUploadBytes;
  try {
    return await body();
  } finally {
    _simpleLimit = oldSimple;
    _maxLimit = oldMax;
  }
}

/// 分块上传的块大小。Graph 要求是 320 KiB 的整数倍。
const int uploadChunkSize = 320 * 1024 * 10;

/// Graph 调用或登录过程中的可读错误。
class GraphError implements Exception {
  final String message;
  final int status;
  final Map<String, dynamic> payload;

  GraphError(this.message, {this.status = 0, Map<String, dynamic>? payload})
      : payload = payload ?? const {};

  String get errorCode {
    final error = payload['error'];
    if (error is String) return error;
    if (error is Map) return '${error['code'] ?? ''}';
    return '';
  }

  @override
  String toString() => message;
}

/// 设备代码登录返回的信息。
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

/// 一次同步的结果，用来拼给用户看的那句话。
class SyncResult {
  final int uploaded;
  final int deleted;
  final int skipped;
  final String account;

  const SyncResult({
    required this.uploaded,
    required this.deleted,
    required this.skipped,
    required this.account,
  });

  String get summary {
    final who = account.isEmpty ? 'Microsoft 账号' : account;
    if (uploaded == 0 && deleted == 0) {
      return '已用 $who 检查完毕，$skipped 个文件都是最新的';
    }
    final parts = <String>['上传 $uploaded'];
    if (deleted > 0) parts.add('删除 $deleted');
    return '已用 $who 同步：${parts.join('，')}，跳过 $skipped';
  }
}

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

class OneDriveService {
  final AppPaths paths;
  final Config config;

  OneDriveService(this.paths, this.config);

  /// 可注入的 HTTP 客户端，测试时替换成假的。
  HttpClient? httpClient;

  /// 测试注入点：把登录服务与 Graph 基址指向本地假服务器。
  String? endpointOverride;
  String? graphEndpointOverride;
  String? deviceCodeEndpointOverride;
  String? tokenEndpointOverride;

  // ------------------------------------------------------------------
  // 配置读数
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

  /// `appfolder` 表示只读写应用私有目录，`full` 表示全盘根目录。
  String get rootMode {
    final raw = '${config.get('onedrive.root_mode', 'appfolder') ?? ''}'.trim();
    return raw == 'full' ? 'full' : 'appfolder';
  }

  bool get isAppFolder => rootMode == 'appfolder';

  String get _scopes => isAppFolder ? _scopeAppFolder : _scopeFull;

  // ------------------------------------------------------------------
  // HTTP 基础
  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _request(
    String method,
    String url, {
    String? token,
    Map<String, String>? form,
    Map<String, dynamic>? jsonBody,
    List<int>? raw,
    Map<String, String>? extraHeaders,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final client = httpClient ?? HttpClient();
    final ownsClient = httpClient == null;
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.headers.set('Accept', 'application/json');
      request.headers.set('User-Agent', 'MemoNest/2.1');

      // contentLength 一设 headers 就锁死，Authorization 必须先设。
      if (token != null && token.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $token');
      }
      if (extraHeaders != null) {
        for (final entry in extraHeaders.entries) {
          request.headers.set(entry.key, entry.value);
        }
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
  // PKCE 授权码流程（默认）
  // ------------------------------------------------------------------

  /// 生成一对 PKCE 凭据。返回 `(codeVerifier, codeChallenge)`。
  static (String, String) generatePkce() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(48, (_) => rnd.nextInt(256));
    final verifier = base64Url
        .encode(bytes)
        .replaceAll('=', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
    final digest = _sha256(utf8.encode(verifier));
    final challenge = base64Url
        .encode(digest)
        .replaceAll('=', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
    return (verifier, challenge);
  }

  /// 纯 Dart 的 SHA-256。为了不引入 crypto 依赖，这里手写一份。
  static List<int> _sha256(List<int> data) {
    const k = <int>[
      0x428a2f98,
      0x71374491,
      0xb5c0fbcf,
      0xe9b5dba5,
      0x3956c25b,
      0x59f111f1,
      0x923f82a4,
      0xab1c5ed5,
      0xd807aa98,
      0x12835b01,
      0x243185be,
      0x550c7dc3,
      0x72be5d74,
      0x80deb1fe,
      0x9bdc06a7,
      0xc19bf174,
      0xe49b69c1,
      0xefbe4786,
      0x0fc19dc6,
      0x240ca1cc,
      0x2de92c6f,
      0x4a7484aa,
      0x5cb0a9dc,
      0x76f988da,
      0x983e5152,
      0xa831c66d,
      0xb00327c8,
      0xbf597fc7,
      0xc6e00bf3,
      0xd5a79147,
      0x06ca6351,
      0x14292967,
      0x27b70a85,
      0x2e1b2138,
      0x4d2c6dfc,
      0x53380d13,
      0x650a7354,
      0x766a0abb,
      0x81c2c92e,
      0x92722c85,
      0xa2bfe8a1,
      0xa81a664b,
      0xc24b8b70,
      0xc76c51a3,
      0xd192e819,
      0xd6990624,
      0xf40e3585,
      0x106aa070,
      0x19a4c116,
      0x1e376c08,
      0x2748774c,
      0x34b0bcb5,
      0x391c0cb3,
      0x4ed8aa4a,
      0x5b9cca4f,
      0x682e6ff3,
      0x748f82ee,
      0x78a5636f,
      0x84c87814,
      0x8cc70208,
      0x90befffa,
      0xa4506ceb,
      0xbef9a3f7,
      0xc67178f2,
    ];
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    final msg = <int>[...data, 0x80];
    while (msg.length % 64 != 56) {
      msg.add(0);
    }
    final bitLen = data.length * 8;
    for (var i = 7; i >= 0; i--) {
      msg.add((bitLen >> (i * 8)) & 0xff);
    }

    int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

    for (var chunk = 0; chunk < msg.length; chunk += 64) {
      final w = List<int>.filled(64, 0);
      for (var i = 0; i < 16; i++) {
        w[i] = (msg[chunk + i * 4] << 24) |
            (msg[chunk + i * 4 + 1] << 16) |
            (msg[chunk + i * 4 + 2] << 8) |
            msg[chunk + i * 4 + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (var i = 0; i < 64; i++) {
        final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        final ch = (e & f) ^ ((~e) & g);
        final t1 = (h + s1 + ch + k[i] + w[i]) & 0xffffffff;
        final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final t2 = (s0 + maj) & 0xffffffff;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xffffffff;
      }
      h0 = (h0 + a) & 0xffffffff;
      h1 = (h1 + b) & 0xffffffff;
      h2 = (h2 + c) & 0xffffffff;
      h3 = (h3 + d) & 0xffffffff;
      h4 = (h4 + e) & 0xffffffff;
      h5 = (h5 + f) & 0xffffffff;
      h6 = (h6 + g) & 0xffffffff;
      h7 = (h7 + h) & 0xffffffff;
    }
    final out = <int>[];
    for (final v in [h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.addAll(
          [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
    }
    return out;
  }

  /// 完整授权码流程：起本地回环监听 → 开浏览器 → 等回调 → 换令牌。
  ///
  /// [onUrl] 让调用方自己打开浏览器（桌面端用 url_launcher）。
  /// 返回授权码换来的令牌响应，调用方再交给 [saveTokens]。
  Future<Map<String, dynamic>> loginWithPkce({
    required void Function(String url) onUrl,
    bool Function()? shouldStop,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    if (clientId.isEmpty) {
      throw GraphError('请先填写 Azure 应用的客户端 ID');
    }
    final (verifier, challenge) = generatePkce();

    // 选一个空闲端口。范围挑在 Windows 动态端口段起点，避开常见占用。
    HttpServer? server;
    for (var port = 53782; port < 53882; port++) {
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        break;
      } on SocketException {
        continue;
      }
    }
    if (server == null) {
      throw GraphError('没有可用的本地端口，无法接收登录回调');
    }
    final redirectUri = 'http://127.0.0.1:${server.port}/callback';

    final authorizeUrl = Uri.parse('$_authority/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'response_mode': 'query',
        'scope': _scopes,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'prompt': 'select_account',
      },
    ).toString();

    final completer = Completer<String>();
    final sub = server.listen((request) async {
      final code = request.uri.queryParameters['code'];
      final error = request.uri.queryParameters['error_description'] ??
          request.uri.queryParameters['error'];
      final response = request.response;
      response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      if (code != null && code.isNotEmpty) {
        response.write(_callbackPage('授权成功，可以回到 MemoNest 了。', true));
        await response.close();
        if (!completer.isCompleted) completer.complete(code);
      } else {
        response.write(_callbackPage('授权失败：${error ?? '没有拿到授权码'}', false));
        await response.close();
        if (!completer.isCompleted) {
          completer.completeError(GraphError('授权失败：${error ?? '没有拿到授权码'}'));
        }
      }
    });

    try {
      onUrl(authorizeUrl);
      final code = await completer.future.timeout(timeout, onTimeout: () {
        throw GraphError('登录超时，请重试');
      });
      return await _request(
        'POST',
        _tokenUrl,
        form: {
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': verifier,
          'scope': _scopes,
        },
      );
    } finally {
      await sub.cancel();
      await server.close(force: true);
      if (shouldStop != null && shouldStop()) {
        // 只是记录，真正取消由超时或调用方处理
      }
    }
  }

  static String _callbackPage(String message, bool ok) {
    final color = ok ? '#2E7D32' : '#C62828';
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<title>MemoNest</title></head>'
        '<body style="font-family:system-ui;display:flex;align-items:center;'
        'justify-content:center;height:100vh;margin:0;background:#FFF8D9">'
        '<div style="text-align:center"><h2 style="color:$color">'
        '$message</h2><p style="color:#8A7A45">这个窗口可以关掉了。</p>'
        '</div></body></html>';
  }

  // ------------------------------------------------------------------
  // 设备代码流程（兜底）
  // ------------------------------------------------------------------

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
    for (final key in ['access_token', 'refresh_token', 'account']) {
      config.set('onedrive.$key', '');
    }
    config.set('onedrive.expires_at', 0);
    config.save();
    // 登录状态换了就作废增量基线，否则下次会以为云端还是老样子。
    try {
      final baseline = File(_baselinePath);
      if (baseline.existsSync()) baseline.deleteSync();
    } on FileSystemException {
      // 删不掉不影响后面同步，最多多传一次
    }
  }

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

  // ------------------------------------------------------------------
  // 远端路径
  // ------------------------------------------------------------------

  /// App Folder 模式的根前缀；全盘模式是空串（直接用 `/me/drive/root`）。
  String get _rootPrefix =>
      isAppFolder ? '/me/drive/special/approot' : '/me/drive/root';

  /// 同步根目录下的子文件夹名。
  String get subfolder {
    final raw = '${config.get('onedrive.subfolder', 'MemoNest') ?? ''}';
    final trimmed = raw.replaceAll(RegExp(r'^/+|/+$'), '').trim();
    return trimmed.isEmpty ? 'MemoNest' : trimmed;
  }

  /// 转义路径。Graph 要求保留 `/` 作层级分隔，其余逐段百分号编码。
  static String _quote(String path) {
    final trimmed = path.replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
  }

  Future<Map<String, dynamic>> _graph(
    String method,
    String path, {
    Map<String, dynamic>? jsonBody,
    List<int>? raw,
    Map<String, String>? extraHeaders,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final token = await accessToken();
    return _request(
      method,
      '$_graphRoot$path',
      token: token,
      jsonBody: jsonBody,
      raw: raw,
      extraHeaders: extraHeaders,
      timeout: timeout,
    );
  }

  /// 把一个相对路径（如 `notes/xx.md`）换成 Graph 可用的 item 路径。
  String _itemPath(String relative) {
    final rel = relative.replaceAll(RegExp(r'^/+'), '');
    final base = isAppFolder ? '/me/drive/special/approot' : '/me/drive/root';
    return '$base:/${_quote(rel)}:';
  }

  String _childrenPath(String relative) {
    final rel = relative.replaceAll(RegExp(r'^/+|/+$'), '');
    return rel.isEmpty ? '$_rootPrefix/children' : '${_itemPath(rel)}/children';
  }

  // ------------------------------------------------------------------
  // 目录与文件
  // ------------------------------------------------------------------

  Future<void> ensureFolder(String folder) async {
    var current = '';
    for (final part in folder.split('/').where((s) => s.isNotEmpty)) {
      final parent = current.isEmpty
          ? '$_rootPrefix/children'
          : '${_itemPath(current)}/children';
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

  /// 上传一个文件。超过 simple upload 上限时自动走分块会话。
  Future<void> uploadFile(String localPath, String folder,
      {String? name}) async {
    final file = File(localPath);
    if (!file.existsSync()) {
      throw GraphError('找不到要上传的文件：$localPath');
    }
    final data = file.readAsBytesSync();
    await ensureFolder(folder);
    final base = name ?? p.basename(localPath);
    final relative = folder.replaceAll(RegExp(r'^/+|/+$'), '').isEmpty
        ? base
        : '${folder.replaceAll(RegExp(r'^/+|/+$'), '')}/$base';

    if (data.length > _maxLimit) {
      throw GraphError('文件超过 250GB Graph 上限，无法上传');
    }
    if (data.length <= _simpleLimit) {
      await _graph('PUT', '${_itemPath(relative)}/content', raw: data);
      return;
    }
    await _uploadLarge(relative, data);
  }

  /// 大文件分块上传：先建 upload session，再把块按顺序 PUT 上去。
  Future<void> _uploadLarge(String relative, List<int> data) async {
    final session = await _graph(
      'POST',
      '${_itemPath(relative)}:/createUploadSession',
      jsonBody: {
        'item': {
          '@microsoft.graph.conflictBehavior': 'replace',
          'name': p.basename(relative),
        }
      },
    );
    final uploadUrl = '${session['uploadUrl'] ?? ''}';
    if (uploadUrl.isEmpty) {
      throw GraphError('创建上传会话失败');
    }
    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + uploadChunkSize, data.length);
      final chunk = data.sublist(offset, end);
      // upload session 的 URL 自带鉴权，不能再带 Authorization。
      await _request(
        'PUT',
        uploadUrl,
        raw: chunk,
        extraHeaders: {
          'Content-Range': 'bytes $offset-${end - 1}/${data.length}',
        },
        timeout: const Duration(minutes: 5),
      );
      offset = end;
    }
  }

  Future<List<Map<String, dynamic>>> listChildren(String folder) async {
    final data = await _graph(
      'GET',
      '${_childrenPath(folder)}?\$select=id,name,size,lastModifiedDateTime,file,folder&\$top=200',
    );
    final value = data['value'];
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> deleteItem(String itemId) async {
    await _graph('DELETE', '/me/drive/items/${Uri.encodeComponent(itemId)}');
  }

  // ------------------------------------------------------------------
  // 增量同步
  // ------------------------------------------------------------------

  String get _baselinePath => p.join(paths.dataDir, 'onedrive-sync.json');

  /// 上一次同步记下来的远端状态：`相对路径 -> "size:mtime"`。
  Map<String, String> _loadBaseline() {
    final file = File(_baselinePath);
    if (!file.existsSync()) return {};
    try {
      final decoded = json.decode(file.readAsStringSync());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', '${value ?? ''}'));
      }
    } on FormatException {
      return {};
    } on FileSystemException {
      return {};
    }
    return {};
  }

  void _saveBaseline(Map<String, String> baseline) {
    try {
      File(_baselinePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(baseline),
        encoding: utf8,
      );
    } on FileSystemException {
      // 写不进去最多下次多传一遍
    }
  }

  /// 收集要同步的本地文件：`相对路径 -> (绝对路径, size, mtime)`。
  Map<String, ({String path, int size, int mtime})> collectLocal() {
    final out = <String, ({String path, int size, int mtime})>{};

    void addFile(String relative, File file) {
      try {
        final stat = file.statSync();
        out[relative] = (
          path: file.path,
          size: stat.size,
          mtime: stat.modified.millisecondsSinceEpoch,
        );
      } on FileSystemException {
        // 读到一半被删了就算了
      }
    }

    final notesDir = Directory(paths.notesDir);
    if (notesDir.existsSync()) {
      for (final entity in notesDir.listSync(recursive: true)) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        // assets 目录里是粘贴的图片，也要同步
        if (!lower.endsWith('.md') &&
            !lower.endsWith('.png') &&
            !lower.endsWith('.jpg') &&
            !lower.endsWith('.jpeg') &&
            !lower.endsWith('.gif') &&
            !lower.endsWith('.webp')) {
          continue;
        }
        final rel = p.relative(entity.path, from: paths.notesDir);
        addFile('notes/${rel.replaceAll('\\', '/')}', entity);
      }
    }

    final index = File(paths.indexPath);
    if (index.existsSync()) addFile('index.json', index);

    final itemsDir = Directory(paths.vaultItemsDir);
    if (itemsDir.existsSync()) {
      for (final entity in itemsDir.listSync()) {
        if (entity is! File) continue;
        if (!entity.path.toLowerCase().endsWith('.mdenc')) continue;
        addFile('vault/items/${p.basename(entity.path)}', entity);
      }
    }

    final meta = File(paths.vaultMetaPath);
    if (meta.existsSync()) addFile('vault/vault.json', meta);

    return out;
  }

  /// 逐个文件增量同步。
  ///
  /// 只传 `size + mtime` 与上次记录不同的文件；本地已删除、上次却同步过的
  /// 文件，从云端删掉。最后把新的基线写回本地。
  Future<SyncResult> syncIncremental({bool mirrorNotes = true}) async {
    if (clientId.isEmpty &&
        !isLoggedIn &&
        '${config.get('onedrive.access_token', '') ?? ''}'.isEmpty) {
      throw GraphError('尚未配置 OneDrive 账号，请先在设置里登录');
    }
    final root = subfolder;
    await ensureFolder(root);

    final baseline = _loadBaseline();
    final local = collectLocal();
    final mirror = mirrorNotes;

    var uploaded = 0;
    var skipped = 0;
    var deleted = 0;
    final next = <String, String>{};

    for (final entry in local.entries) {
      final rel = entry.key;
      // mirror_notes 关掉时笔记与图片都不传，其余（index.json / vault）照传。
      if (!mirror && rel.startsWith('notes/')) continue;
      final info = entry.value;
      final stamp = '${info.size}:${info.mtime}';
      if (baseline[rel] == stamp) {
        next[rel] = stamp;
        skipped++;
        continue;
      }
      final folder = rel.contains('/')
          ? '$root/${rel.substring(0, rel.lastIndexOf('/'))}'
          : root;
      await uploadFile(info.path, folder);
      next[rel] = stamp;
      uploaded++;
    }

    // 上次同步过、这次本地已经没有的 → 从云端删掉。
    for (final rel in baseline.keys) {
      if (local.containsKey(rel)) continue;
      if (!mirror && rel.startsWith('notes/')) continue;
      final folder = rel.contains('/')
          ? '$root/${rel.substring(0, rel.lastIndexOf('/'))}'
          : root;
      final name = p.basename(rel);
      try {
        final children = await listChildren(folder);
        for (final item in children) {
          if ('${item['name'] ?? ''}' != name) continue;
          final id = '${item['id'] ?? ''}';
          if (id.isEmpty) continue;
          await deleteItem(id);
          deleted++;
        }
      } on GraphError {
        // 目录已经不存在，不用删
      }
    }

    _saveBaseline(next);
    return SyncResult(
      uploaded: uploaded,
      deleted: deleted,
      skipped: skipped,
      account: account,
    );
  }

  /// 兼容旧调用的整包同步：先做增量，再传一份快照。
  Future<String> sync({File? snapshot}) async {
    final result = await syncIncremental(
      mirrorNotes: config.get('onedrive.mirror_notes', true) == true,
    );
    if (snapshot != null && snapshot.existsSync()) {
      await uploadFile(snapshot.path, subfolder);
      final keep = _asInt(config.get('onedrive.keep_backups', 30), 30);
      await _prune(subfolder, keep);
    }
    return result.summary;
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

  /// 一键登录：PKCE 优先，失败时把错误抛给调用方决定要不要切设备码。
  Future<String> loginPkce({required void Function(String url) onUrl}) async {
    final payload = await loginWithPkce(onUrl: onUrl);
    await saveTokens(payload);
    return fetchAccount();
  }

  Future<String> loginDeviceFlow({
    void Function(DeviceCodeInfo info)? onCode,
    bool Function()? shouldStop,
  }) async {
    final info = await startDeviceFlow();
    onCode?.call(info);
    final payload = await pollDeviceToken(info, shouldStop: shouldStop);
    await saveTokens(payload);
    return fetchAccount();
  }
}
