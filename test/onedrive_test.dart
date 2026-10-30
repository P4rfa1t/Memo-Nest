/// OneDrive Graph 客户端测试：设备代码登录、令牌续期、目录与上传。
///
/// 全部打在本地起的假服务器上——不联网、不需要真实 Azure 应用，
/// 但走的是真实的 HTTP 路径（HttpClient 没被 mock 掉），
/// 所以编码、状态码、错误分支都是真的在跑。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:memonest/core/onedrive.dart';
import 'package:memonest/core/paths.dart';
import 'package:path/path.dart' as p;

late Directory tmpRoot;

/// 一次请求的记录，断言时用。
class RecordedRequest {
  final String method;
  final String path;
  final Map<String, String> query;
  final String body;
  final String? auth;

  RecordedRequest(this.method, this.path, this.query, this.body, this.auth);

  @override
  String toString() => '$method $path';
}

/// 假 Graph / 登录服务器。
///
/// [handler] 拿到请求返回 (状态码, JSON 字符串)；返回 null 表示 404。
class FakeServer {
  late HttpServer _server;
  final List<RecordedRequest> requests = [];
  late Future<Object?> Function(RecordedRequest) handler;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final bytes = await req.fold<List<int>>(<int>[], (acc, chunk) {
        acc.addAll(chunk);
        return acc;
      });
      final body = utf8.decode(bytes, allowMalformed: true);
      final recorded = RecordedRequest(
        req.method,
        req.uri.path,
        req.uri.queryParameters,
        body,
        req.headers.value('authorization'),
      );
      requests.add(recorded);
      final result = await handler(recorded);
      if (result == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final (status, payload) = result as (int, String);
      req.response.statusCode = status;
      req.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      req.response.write(payload);
      await req.response.close();
    });
  }

  Future<void> stop() async => _server.close(force: true);

  List<RecordedRequest> where(String method, String pathPart) => requests
      .where((r) => r.method == method && r.path.contains(pathPart))
      .toList();
}

AppPaths makePaths(String name) {
  final root = Directory(p.join(tmpRoot.path, name))
    ..createSync(recursive: true);
  final paths = AppPaths(root)..ensureDirs();
  return paths;
}

/// 把服务指向假服务器：authority 与 graph 基址都被替换掉。
///
/// 生产代码里这两个地址是写死的常量，靠 [OneDriveService.endpointOverride]
/// 这类注入点改指向。
OneDriveService makeService(
  AppPaths paths,
  Config config,
  FakeServer server,
) {
  return OneDriveService(paths, config)
    ..deviceCodeEndpointOverride = '${server.base}/devicecode'
    ..tokenEndpointOverride = '${server.base}/token'
    ..graphEndpointOverride = '${server.base}/graph';
}

/// 造一个设备代码信息，测试里只关心轮询间隔。
DeviceCodeInfo makeInfo({int interval = 1, int expiresIn = 900}) {
  return DeviceCodeInfo(
    deviceCode: 'dev-1',
    userCode: 'ABCD-1234',
    verificationUri: 'https://microsoft.com/devicelogin',
    expiresIn: expiresIn,
    interval: interval,
    message: '打开网页输码',
  );
}

void main() {
  setUpAll(() {
    tmpRoot = Directory.systemTemp.createTempSync('memonest_onedrive_');
  });

  tearDownAll(() {
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
  });

  group('设备代码登录', () {
    late FakeServer server;
    late AppPaths paths;
    late Config config;
    late OneDriveService service;

    setUp(() async {
      server = FakeServer();
      await server.start();
      paths = makePaths('login_${DateTime.now().microsecondsSinceEpoch}');
      config = Config(paths.configPath);
      config.set('onedrive.client_id', 'client-abc');
      config.set('onedrive.tenant', 'common');
      service = makeService(paths, config, server);
    });

    tearDown(() async => server.stop());

    test('startDeviceFlow 发对表单并解析出用户码', () async {
      server.handler = (req) async => (
            200,
            json.encode({
              'device_code': 'dev-1',
              'user_code': 'ABCD-1234',
              'verification_uri': 'https://microsoft.com/devicelogin',
              'expires_in': 900,
              'interval': 5,
              'message': '打开网页输码',
            })
          );

      final info = await service.startDeviceFlow();
      expect(info.deviceCode, 'dev-1');
      expect(info.userCode, 'ABCD-1234');
      expect(info.verificationUri, 'https://microsoft.com/devicelogin');
      expect(info.expiresIn, 900);
      expect(info.interval, 5);

      final sent = server.where('POST', '/devicecode').single;
      expect(sent.body, contains('client_id=client-abc'));
      expect(sent.body, contains('scope=offline_access'));
      expect(sent.body, contains('Files.ReadWrite'));
    });

    test('没有客户端 ID 直接报可读错误', () async {
      config.set('onedrive.client_id', '');
      expect(
        () => service.startDeviceFlow(),
        throwsA(isA<GraphError>()
            .having((e) => e.message, 'message', contains('客户端 ID'))),
      );
      expect(server.requests, isEmpty);
    });

    test('轮询跳过 authization_pending，成功后存下令牌', () async {
      var polls = 0;
      server.handler = (req) async {
        if (req.path.endsWith('/token')) {
          polls++;
          if (polls < 3) {
            return (400, json.encode({'error': 'authorization_pending'}));
          }
          return (
            200,
            json.encode({
              'access_token': 'at-1',
              'refresh_token': 'rt-1',
              'expires_in': 3600,
            })
          );
        }
        // /me
        return (
          200,
          json.encode(
              {'displayName': '张三', 'userPrincipalName': 'z@example.com'})
        );
      };

      final info = makeInfo();

      final payload = await service.pollDeviceToken(info);
      expect(payload['access_token'], 'at-1');
      expect(polls, 3);

      await service.saveTokens(payload, accountName: '张三');
      expect(config.get('onedrive.refresh_token'), 'rt-1');
      expect(config.get('onedrive.account'), '张三');
      final expiresAt = config.get('onedrive.expires_at') as int;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // expires_in 3600，代码里留 60 秒余量
      expect(expiresAt - now, inInclusiveRange(3500, 3600));
    });

    test('slow_down 会拉长间隔而不是失败', () async {
      var polls = 0;
      server.handler = (req) async {
        polls++;
        if (polls == 1) {
          return (400, json.encode({'error': 'slow_down'}));
        }
        return (200, json.encode({'access_token': 'at', 'expires_in': 3600}));
      };
      final info = makeInfo();
      final payload = await service.pollDeviceToken(info);
      expect(payload['access_token'], 'at');
      expect(polls, 2);
    });

    test('被拒绝与过期给出各自的中文提示', () async {
      final info = makeInfo();

      // 必须 await：不 await 的话第一次轮询还在飞，下面换掉 handler
      // 就会把第一次请求导到 expired_token 分支去。
      server.handler =
          (req) async => (400, json.encode({'error': 'access_denied'}));
      await expectLater(
        service.pollDeviceToken(info),
        throwsA(isA<GraphError>().having((e) => e.message, 'message', '授权被拒绝')),
      );

      server.handler =
          (req) async => (400, json.encode({'error': 'expired_token'}));
      await expectLater(
        service.pollDeviceToken(info),
        throwsA(isA<GraphError>()
            .having((e) => e.message, 'message', contains('已过期'))),
      );
    });

    test('shouldStop 能在轮询中提前退出', () async {
      server.handler =
          (req) async => (400, json.encode({'error': 'authorization_pending'}));
      final info = makeInfo();
      var stopped = false;
      Future.delayed(const Duration(milliseconds: 300), () => stopped = true);
      expect(
        () => service.pollDeviceToken(info, shouldStop: () => stopped),
        throwsA(isA<GraphError>().having((e) => e.message, 'message', '已取消登录')),
      );
    });
  });

  group('令牌', () {
    late FakeServer server;
    late AppPaths paths;
    late Config config;
    late OneDriveService service;

    setUp(() async {
      server = FakeServer();
      await server.start();
      paths = makePaths('token_${DateTime.now().microsecondsSinceEpoch}');
      config = Config(paths.configPath);
      config.set('onedrive.client_id', 'client-abc');
      service = makeService(paths, config, server);
    });

    tearDown(() async => server.stop());

    test('没过期就直接用缓存，不发请求', () async {
      config.set('onedrive.access_token', 'cached');
      config.set('onedrive.expires_at',
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600);
      final token = await service.accessToken();
      expect(token, 'cached');
      expect(server.requests, isEmpty);
    });

    test('过期后用 refresh_token 续期并落盘', () async {
      config.set('onedrive.access_token', 'old');
      config.set('onedrive.expires_at', 1);
      config.set('onedrive.refresh_token', 'rt-1');
      server.handler = (req) async => (
            200,
            json.encode({
              'access_token': 'new-at',
              'refresh_token': 'rt-2',
              'expires_in': 3600,
            })
          );

      final token = await service.accessToken();
      expect(token, 'new-at');
      expect(config.get('onedrive.access_token'), 'new-at');
      expect(config.get('onedrive.refresh_token'), 'rt-2');
      final sent = server.requests.first;
      expect(sent.body, contains('grant_type=refresh_token'));
      expect(sent.body, contains('refresh_token=rt-1'));
    });

    test('没有 refresh_token 时提示先登录', () async {
      expect(
        () => service.accessToken(),
        throwsA(isA<GraphError>()
            .having((e) => e.message, 'message', contains('尚未登录'))),
      );
    });

    test('forceRefresh 绕过缓存', () async {
      config.set('onedrive.access_token', 'cached');
      config.set('onedrive.expires_at',
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600);
      config.set('onedrive.refresh_token', 'rt-1');
      server.handler = (req) async =>
          (200, json.encode({'access_token': 'forced', 'expires_in': 3600}));
      final token = await service.accessToken(forceRefresh: true);
      expect(token, 'forced');
    });

    test('logout 清干净', () async {
      config.set('onedrive.access_token', 'a');
      config.set('onedrive.refresh_token', 'r');
      config.set('onedrive.account', 'x');
      config.set('onedrive.expires_at', 123);
      service.logout();
      expect(config.get('onedrive.refresh_token'), '');
      expect(config.get('onedrive.access_token'), '');
      expect(config.get('onedrive.account'), '');
      expect(config.get('onedrive.expires_at'), 0);
      expect(service.isLoggedIn, isFalse);
    });
  });

  group('目录与上传', () {
    late FakeServer server;
    late AppPaths paths;
    late Config config;
    late OneDriveService service;

    setUp(() async {
      server = FakeServer();
      await server.start();
      paths = makePaths('upload_${DateTime.now().microsecondsSinceEpoch}');
      config = Config(paths.configPath);
      config.set('onedrive.access_token', 'at');
      config.set('onedrive.expires_at',
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600);
      service = makeService(paths, config, server);
    });

    tearDown(() async => server.stop());

    test('ensureFolder 逐级创建，409 当成功', () async {
      final created = <String>[];
      server.handler = (req) async {
        final map = json.decode(req.body) as Map<String, dynamic>;
        final name = '${map['name']}';
        if (name == 'MemoNest备份') {
          // 第一级已存在
          return (
            409,
            json.encode({
              'error': {'code': 'nameAlreadyExists'}
            })
          );
        }
        created.add(name);
        return (201, json.encode({'name': name}));
      };

      await service.ensureFolder('MemoNest备份/notes');

      expect(created, ['notes']);
      expect(server.requests.length, 2);
      // 第一级走 root/children，第二级走带路径的形式
      expect(server.requests[0].path, '/graph/me/drive/root/children');
      expect(
        server.requests[1].path,
        contains('/me/drive/root:/MemoNest%E5%A4%87%E4%BB%BD:/children'),
      );
    });

    test('ensureFolder 把非 409 的错误往上抛', () async {
      server.handler = (req) async => (
            403,
            json.encode({
              'error': {'message': '没有权限'}
            })
          );
      expect(
        () => service.ensureFolder('a'),
        throwsA(isA<GraphError>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.message, 'message', '没有权限')),
      );
    });

    test('uploadFile 用 PUT 发原始字节，路径做了百分号编码', () async {
      final local = File(p.join(paths.dataDir, '待上传.md'))
        ..writeAsBytesSync(utf8.encode('hello'));
      server.handler = (req) async => (201, json.encode({'id': 'x'}));

      await service.uploadFile(local.path, 'MemoNest备份', name: '笔记 1.md');

      final puts = server.where('PUT', '/content');
      // 目录创建 + 文件上传
      expect(puts.length, 1);
      final sent = puts.single;
      expect(sent.path, contains('%E7%AC%94%E8%AE%B0%201.md'));
      expect(sent.auth, 'Bearer at');
    });

    test('超过 250MB 直接报错，不发上传请求', () async {
      final local = File(p.join(paths.dataDir, 'big.bin'));
      // 不真的写 250MB，用稀疏文件
      final raf = local.openSync(mode: FileMode.write);
      raf.truncateSync(simpleUploadLimit + 1);
      raf.closeSync();
      addTearDown(() {
        try {
          local.deleteSync();
        } on FileSystemException {
          // 忽略
        }
      });

      expect(
        () => service.uploadFile(local.path, 'x'),
        throwsA(isA<GraphError>()
            .having((e) => e.message, 'message', contains('250MB'))),
      );
      expect(server.where('PUT', '/content'), isEmpty);
    });

    test('listChildren 解析 value 数组', () async {
      server.handler = (req) async => (
            200,
            json.encode({
              'value': [
                {'id': '1', 'name': 'a.md'},
                {'id': '2', 'name': 'b.md'},
              ]
            })
          );
      final items = await service.listChildren('folder');
      expect(items.length, 2);
      expect(items[0]['name'], 'a.md');
      // 请求带了 $select 与 $top
      expect(server.requests.single.query.containsKey(r'$select'), isTrue);
    });

    test('listChildren 遇到非列表返回空而不是崩', () async {
      server.handler = (req) async => (200, json.encode({'value': 'oops'}));
      expect(await service.listChildren('folder'), isEmpty);
    });
  });

  group('sync', () {
    late FakeServer server;
    late AppPaths paths;
    late Config config;
    late OneDriveService service;

    setUp(() async {
      server = FakeServer();
      await server.start();
      paths = makePaths('sync_${DateTime.now().microsecondsSinceEpoch}');
      config = Config(paths.configPath);
      config.set('onedrive.access_token', 'at');
      config.set('onedrive.expires_at',
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600);
      config.set('onedrive.account', '张三');
      config.set('onedrive.mirror_notes', true);
      config.set('onedrive.keep_backups', 2);
      service = makeService(paths, config, server);

      File(p.join(paths.notesDir, 'a.md')).writeAsStringSync('# A');
      File(p.join(paths.notesDir, 'b.md')).writeAsStringSync('# B');
    });

    tearDown(() async => server.stop());

    test('上传笔记、删云端多余、传快照并按 keep 清理', () async {
      // 云端 notes 里有一个本地已经不存在的 c.md
      server.handler = (req) async {
        if (req.path.contains('/children') && req.method == 'GET') {
          if (req.path.contains('/notes')) {
            return (
              200,
              json.encode({
                'value': [
                  {'id': 'c-id', 'name': 'c.md'},
                  {'id': 'a-id', 'name': 'a.md'},
                ]
              })
            );
          }
          // 子目录下的旧备份（快照传在 MemoNest备份/ 里，清理也只看这里）
          return (
            200,
            json.encode({
              'value': [
                {'id': 'z1', 'name': 'memo-backup-20260101-000000.zip'},
                {'id': 'z2', 'name': 'memo-backup-20260102-000000.zip'},
                {'id': 'z3', 'name': 'memo-backup-20260103-000000.zip'},
                {'id': 'z4', 'name': 'memo-backup-20260104-000000.zip'},
                {'id': 'z5', 'name': 'memo-backup-20260105-1.zip'},
              ]
            })
          );
        }
        if (req.method == 'DELETE') return (204, '');
        if (req.method == 'POST') return (201, json.encode({'id': 'new'}));
        return (201, json.encode({'id': 'put'}));
      };

      final snapshot =
          File(p.join(paths.backupDir, 'memo-backup-20260105-1.zip'))
            ..writeAsBytesSync([1, 2, 3]);

      final message = await service.sync(snapshot: snapshot);
      expect(message, contains('张三'));

      // 两篇笔记 + index 不存在 + 无 vault，所以上传计数是 2
      expect(message, contains('2 篇笔记'));

      // c.md 被删掉了（本地没有）
      final deletes = server.where('DELETE', '/items/');
      expect(
          deletes.map((r) => r.path), contains('/graph/me/drive/items/c-id'));

      // 快照传进子目录后，listChildren 会看到 4 个旧的 + 这次传的 1 个，
      // keep=2 要砍掉最前面的 3 个 → z1、z2、z3。连同 c.md 一共 4 次删除。
      expect(deletes.length, 4);
      expect(deletes.map((r) => r.path), contains('/graph/me/drive/items/z1'));
      expect(deletes.map((r) => r.path), contains('/graph/me/drive/items/z2'));
      expect(deletes.map((r) => r.path), contains('/graph/me/drive/items/z3'));
      expect(
        deletes.map((r) => r.path),
        isNot(contains('/graph/me/drive/items/z4')),
      );
      expect(
        deletes.map((r) => r.path),
        isNot(contains('/graph/me/drive/items/z5')),
      );
    });

    test('mirror_notes 关闭时不传笔记也不碰 notes 目录', () async {
      config.set('onedrive.mirror_notes', false);
      server.handler = (req) async {
        if (req.method == 'GET') return (200, json.encode({'value': []}));
        if (req.method == 'POST') return (201, json.encode({'id': 'n'}));
        return (201, json.encode({'id': 'put'}));
      };

      final snapshot = File(p.join(paths.backupDir, 'memo-backup-1.zip'))
        ..writeAsBytesSync([1]);
      await service.sync(snapshot: snapshot);

      expect(server.where('PUT', '/notes/'), isEmpty);
      expect(server.where('GET', '/notes'), isEmpty);
      // 只上传了快照
      expect(server.where('PUT', '/content').length, 1);
    });

    test('subfolder 为空时落回默认值', () async {
      config.set('onedrive.subfolder', '   ');
      expect(service.subfolder, 'MemoNest备份');
      config.set('onedrive.subfolder', '/自定义/');
      expect(service.subfolder, '自定义');
    });
  });
}
