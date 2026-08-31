import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phone_ai_assistant/services/mcp_transport.dart';

/// 一句 JSON 回复，照着请求里的 id 回。
MockClient jsonServer(
  Map<String, dynamic> Function(Map<String, dynamic> req) reply, {
  Map<String, String> headers = const {},
  void Function(http.Request req)? spy,
}) {
  return MockClient((req) async {
    spy?.call(req);
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode(reply(body)),
      200,
      headers: {'content-type': 'application/json', ...headers},
    );
  });
}

/// SSE 服务器：给一串已经拼好的帧，按行喂回去。
MockClient sseServer(String Function(String id) frames) {
  return MockClient.streaming((req, bodyStream) async {
    final body = jsonDecode(await bodyStream.bytesToString()) as Map;
    final text = frames(body['id'] as String);
    return http.StreamedResponse(
      Stream.value(utf8.encode(text)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

final _endpoint = Uri.parse('https://example.com/mcp');

void main() {
  group('按地址选传输方式', () {
    test('https 走 Streamable HTTP，ws 走 WebSocket', () {
      expect(
        createTransport('https://example.com/mcp'),
        isA<StreamableHttpTransport>(),
      );
      expect(
        createTransport('ws://192.168.1.9:8765'),
        isA<WebSocketTransport>(),
      );
    });

    test('认不出来的地址要当场说清楚，不能等到发请求才炸', () {
      expect(
        () => createTransport('example.com/mcp'), // 忘了写协议头
        throwsA(isA<McpTransportError>()),
      );
    });
  });

  // 整个 token 功能的核心：头拼错了服务器只回一个 401，从外面看不出原因。
  group('Authorization 头', () {
    test('没 token 就不发这个头', () async {
      http.Request? seen;
      final t = StreamableHttpTransport(
        _endpoint,
        client: jsonServer((r) => {'result': {}}, spy: (r) => seen = r),
      );

      await t.request('ping');

      expect(seen!.headers.containsKey('Authorization'), isFalse);
    });

    test('填裸 token，拼成 Bearer', () async {
      http.Request? seen;
      final t = StreamableHttpTransport(
        _endpoint,
        token: 'abc123',
        client: jsonServer((r) => {'result': {}}, spy: (r) => seen = r),
      );

      await t.request('ping');

      expect(seen!.headers['Authorization'], 'Bearer abc123');
    });

    // 从别人的配置文件里复制过来的就是整串。原样再拼一遍会变成
    // `Bearer Bearer abc123`，服务器只回 401，看不出是粘多了。
    test('整串 Bearer 粘进来，不能拼成两个 Bearer', () async {
      http.Request? seen;
      final t = StreamableHttpTransport(
        _endpoint,
        token: 'Bearer abc123',
        client: jsonServer((r) => {'result': {}}, spy: (r) => seen = r),
      );

      await t.request('ping');

      expect(seen!.headers['Authorization'], 'Bearer abc123');
    });

    test('大小写和多余空格都不算数', () async {
      http.Request? seen;
      final t = StreamableHttpTransport(
        _endpoint,
        token: '  bearer   abc123  ',
        client: jsonServer((r) => {'result': {}}, spy: (r) => seen = r),
      );

      await t.request('ping');

      expect(seen!.headers['Authorization'], 'Bearer abc123');
    });
  });

  group('会话', () {
    // 服务器在 initialize 时发一个 session id，后面每个请求都得原样带回去，
    // 否则它不认识我们——症状是「握手过了，然后每一步都失败」。
    test('服务器给的 session id 要带回下一个请求', () async {
      final seen = <http.Request>[];
      final t = StreamableHttpTransport(
        _endpoint,
        client: jsonServer(
          (r) => {'result': {}},
          headers: {'mcp-session-id': 'sess-42'},
          spy: seen.add,
        ),
      );

      await t.request('initialize');
      await t.request('tools/list');

      expect(seen[0].headers.containsKey('Mcp-Session-Id'), isFalse); // 还没拿到
      expect(seen[1].headers['Mcp-Session-Id'], 'sess-42');
    });

    // 协议版本是握手谈定的，谈定之前发等于替服务器做决定。
    test('握手完成前不发协议版本头，之后才发', () async {
      final seen = <http.Request>[];
      final t = StreamableHttpTransport(
        _endpoint,
        client: jsonServer((r) => {'result': {}}, spy: seen.add),
      );

      await t.request('initialize');
      t.onInitialized();
      await t.request('tools/list');

      expect(seen[0].headers.containsKey('MCP-Protocol-Version'), isFalse);
      expect(seen[1].headers['MCP-Protocol-Version'], kMcpProtocolVersion);
    });
  });

  group('SSE 流', () {
    // 同一条流里服务器可以插自己的通知和请求。挑错一条，模型拿到的就是
    // 一段风马牛不相及的东西。
    test('从一堆帧里挑出 id 对得上的那条，跳过服务器自己发的', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: sseServer(
          (id) => 'event: message\n'
              'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n'
              '\n'
              'data: {"jsonrpc":"2.0","id":"别人的","result":{"wrong":true}}\n'
              '\n'
              'data: {"jsonrpc":"2.0","id":"$id","result":{"tools":[]}}\n'
              '\n',
        ),
      );

      final result = await t.request('tools/list');

      expect(result['tools'], isEmpty);
      expect(result.containsKey('wrong'), isFalse);
    });

    test('一个事件跨多行 data:，要拼起来再解析', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: sseServer(
          (id) => 'data: {"jsonrpc":"2.0","id":"$id",\n'
              'data: "result":{"ok":true}}\n'
              '\n',
        ),
      );

      expect((await t.request('ping'))['ok'], isTrue);
    });

    test('注释和心跳帧不能被当成数据', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: sseServer(
          (id) => ': keep-alive\n'
              '\n'
              'retry: 3000\n'
              '\n'
              'data: {"jsonrpc":"2.0","id":"$id","result":{"ok":true}}\n'
              '\n',
        ),
      );

      expect((await t.request('ping'))['ok'], isTrue);
    });

    test('流结束了也没等到自己那条，要报出来而不是静静返回空', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: sseServer((id) => 'data: {"jsonrpc":"2.0","id":"别人的"}\n\n'),
      );

      await expectLater(
        t.request('tools/list'),
        throwsA(
          isA<McpTransportError>().having(
            (e) => e.message,
            'message',
            contains('没有返回结果'),
          ),
        ),
      );
    });
  });

  // 这两条是「AI 读不到我配的 MCP」那类问题里最常见的一步，
  // 文案分不清的话下一步动作就会做错。
  group('鉴权失败要说清楚是哪一种', () {
    Future<String> messageFor(int status, {String? token}) async {
      final t = StreamableHttpTransport(
        _endpoint,
        token: token,
        client: MockClient((r) async => http.Response('nope', status)),
      );
      try {
        await t.request('initialize');
        fail('该抛没抛');
      } on McpTransportError catch (e) {
        return e.message;
      }
    }

    test('没填 token → 让人去填', () async {
      expect(await messageFor(401), contains('填 token'));
    });

    test('填了被拒 → 说 token 有问题，别再让人去填一遍', () async {
      final msg = await messageFor(401, token: 'abc');
      expect(msg, contains('拒绝'));
      expect(msg, isNot(contains('请在下面填')));
    });

    test('403 和 401 同一套说法', () async {
      expect(await messageFor(403), contains('填 token'));
    });

    // ⚠️ token 绝不能出现在任何给人看的文案里。
    test('报错里不能带出 token 本身', () async {
      expect(await messageFor(401, token: 'super-secret'), isNot(contains('super-secret')));
    });
  });

  group('其他失败', () {
    test('服务器 500 时把状态码和响应体一起报出来', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: MockClient((r) async => http.Response('boom', 500)),
      );

      await expectLater(
        t.request('ping'),
        throwsA(
          isA<McpTransportError>().having(
            (e) => e.message,
            'message',
            allOf(contains('500'), contains('boom')),
          ),
        ),
      );
    });

    test('JSON-RPC 层的 error 要变成带 code 的异常，不能当成正常结果', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: jsonServer(
          (r) => {
            'jsonrpc': '2.0',
            'id': r['id'],
            'error': {'code': -32601, 'message': '没有这个方法'},
          },
        ),
      );

      await expectLater(
        t.request('nope'),
        throwsA(
          isA<McpTransportError>()
              .having((e) => e.code, 'code', -32601)
              .having((e) => e.message, 'message', '没有这个方法'),
        ),
      );
    });

    test('批量响应里要认自己那一条', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: MockClient((r) async {
          final id = (jsonDecode(r.body) as Map)['id'];
          return http.Response(
            jsonEncode([
              {'jsonrpc': '2.0', 'id': '别人的', 'result': {'wrong': true}},
              {'jsonrpc': '2.0', 'id': id, 'result': {'mine': true}},
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      expect((await t.request('ping'))['mine'], isTrue);
    });

    test('空响应体不能被当成成功', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: MockClient((r) async => http.Response('', 200)),
      );

      await expectLater(t.request('ping'), throwsA(isA<McpTransportError>()));
    });

    // 通知没有 id、没人等回复，掉了就掉了。让它把整个会话带崩是最糟的：
    // 一次网络抖动 = 所有工具消失。
    test('通知发失败不能把会话带崩', () async {
      final t = StreamableHttpTransport(
        _endpoint,
        client: MockClient((r) async => throw const SocketExceptionStub()),
      );

      await expectLater(t.notify('notifications/initialized'), completes);
    });
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => '网线被拔了';
}
