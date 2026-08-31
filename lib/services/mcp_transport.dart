import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// MCP protocol version this client speaks.
const String kMcpProtocolVersion = '2025-06-18';

/// A JSON-RPC level failure reported by the server, or a transport failure
/// we want to surface with a readable message instead of a bare exception.
class McpTransportError implements Exception {
  final int? code;
  final String message;

  McpTransportError(this.message, {this.code});

  @override
  String toString() => code == null ? message : '[$code] $message';
}

/// How a client talks to an MCP server.
///
/// Two implementations exist:
///  - [StreamableHttpTransport] for `http(s)://` endpoints. This is the
///    transport defined by the MCP spec and what public servers speak.
///  - [WebSocketTransport] for `ws(s)://` endpoints. Not part of the spec,
///    kept because the app's own bundled server uses it.
abstract class McpTransport {
  /// Opens the underlying connection. Throws [McpTransportError] on failure.
  Future<void> open();

  /// Sends a request and waits for its result. Throws [McpTransportError] if the
  /// server answers with an error, or if nothing comes back in time.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout,
  ]);

  /// Sends a notification. Notifications have no id and expect no reply.
  Future<void> notify(String method, [Map<String, dynamic>? params]);

  /// Called once the initialize handshake succeeds, so the transport can
  /// start attaching the negotiated protocol version to later requests.
  void onInitialized() {}

  Future<void> close();
}

/// [token] 只对 HTTP 那条生效，见 `ExternalMcpServer.token`。
McpTransport createTransport(String url, {String? token}) {
  final uri = Uri.parse(url);
  switch (uri.scheme) {
    case 'http':
    case 'https':
      return StreamableHttpTransport(uri, token: token);
    case 'ws':
    case 'wss':
      return WebSocketTransport(uri);
    default:
      throw McpTransportError('不支持的地址：$url\n请用 https:// 或 ws:// 开头');
  }
}

// ---------------------------------------------------------------------------
// Streamable HTTP
// ---------------------------------------------------------------------------

/// The transport from the MCP spec (2025-03-26 onward).
///
/// Every message is POSTed to a single endpoint. The server may answer either
/// with one JSON object (`application/json`) or with an SSE stream
/// (`text/event-stream`) that eventually carries the matching response — both
/// are legal for the same request, so both are handled here.
class StreamableHttpTransport extends McpTransport {
  final Uri endpoint;

  /// 可空。⚠️ 不要打进日志、错误文案或任何界面提示。
  final String? token;

  final http.Client _client = http.Client();

  String? _sessionId;
  bool _initialized = false;
  int _nextId = 0;

  StreamableHttpTransport(this.endpoint, {this.token});

  @override
  Future<void> open() async {
    // Nothing to do: HTTP has no connection to establish up front. The
    // initialize request itself is what proves the endpoint is reachable.
  }

  @override
  void onInitialized() => _initialized = true;

  /// 别人的配置文件（Claude Code 的 `mcpServers.headers`、curl 的 `-H`）里存的
  /// 是**整串** `Bearer xxx`，直接复制过来很自然。原样拼一遍就成了
  /// `Bearer Bearer xxx`，服务器只会回一个 401，看不出是粘贴粘多了。
  /// 两种写法都收下。
  String? get _bearer {
    final t = token?.trim();
    if (t == null || t.isEmpty) return null;
    final lower = t.toLowerCase();
    if (lower.startsWith('bearer ')) {
      final rest = t.substring(7).trim();
      return rest.isEmpty ? null : rest;
    }
    return t;
  }

  Map<String, String> _headers() {
    final bearer = _bearer;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/event-stream',
      if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      // Only sent once the handshake settled on a version.
      if (_initialized) 'MCP-Protocol-Version': kMcpProtocolVersion,
      // 从第一个请求（initialize）就要带上：要鉴权的服务器连握手都会 401。
      if (bearer != null) 'Authorization': 'Bearer $bearer',
    };
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final id = 'req_${++_nextId}';
    final body = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };

    final http.StreamedResponse resp;
    try {
      final req = http.Request('POST', endpoint)
        ..headers.addAll(_headers())
        ..body = jsonEncode(body);
      resp = await _client.send(req).timeout(timeout);
    } on TimeoutException {
      throw McpTransportError('请求超时（${timeout.inSeconds}s）：$method');
    } catch (e) {
      throw McpTransportError('连接失败：$e');
    }

    // The server hands out a session id on initialize; every later request
    // has to carry it back or the server will not recognise us.
    final sid = resp.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;

    if (resp.statusCode == 404 && _sessionId != null) {
      _sessionId = null;
      _initialized = false;
      throw McpTransportError('会话已过期，请重新连接');
    }
    // 鉴权失败单独说人话：光看「HTTP 401」分不清是没填 token 还是填错了，
    // 而这两种的下一步动作完全不同。
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      await resp.stream.drain<void>();
      final hasToken = token != null && token!.isNotEmpty;
      throw McpTransportError(
        hasToken
            ? '服务器拒绝了这个 token（HTTP ${resp.statusCode}）——可能过期或没有权限'
            : '这台服务器需要鉴权（HTTP ${resp.statusCode}），请在下面填 token',
      );
    }
    if (resp.statusCode >= 400) {
      final text = await resp.stream.bytesToString();
      throw McpTransportError(
        'HTTP ${resp.statusCode}${text.isEmpty ? '' : '：${_clip(text)}'}',
      );
    }

    final contentType = resp.headers['content-type'] ?? '';

    if (contentType.contains('text/event-stream')) {
      final msg = await _readSseUntil(resp, id, timeout);
      if (msg == null) throw McpTransportError('服务器结束了流但没有返回结果：$method');
      return _unwrap(msg);
    }

    final text = await resp.stream.bytesToString();
    if (text.trim().isEmpty) throw McpTransportError('服务器返回了空响应：$method');
    final decoded = jsonDecode(text);
    if (decoded is List) {
      // Batched reply: find ours.
      for (final m in decoded) {
        if (m is Map && m['id'] == id) {
          return _unwrap(Map<String, dynamic>.from(m));
        }
      }
      throw McpTransportError('批量响应里没有找到 id=$id 的结果');
    }
    return _unwrap(Map<String, dynamic>.from(decoded as Map));
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    final body = {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    try {
      final req = http.Request('POST', endpoint)
        ..headers.addAll(_headers())
        ..body = jsonEncode(body);
      final resp = await _client
          .send(req)
          .timeout(const Duration(seconds: 10));
      // 202 with an empty body is the expected answer; drain anything else so
      // the socket can be reused.
      await resp.stream.drain();
    } catch (_) {
      // A dropped notification must not take the session down.
    }
  }

  /// Reads the SSE body until the message whose `id` matches shows up.
  ///
  /// Server-initiated requests and notifications can be interleaved in the
  /// same stream; those are skipped rather than mistaken for our answer.
  Future<Map<String, dynamic>?> _readSseUntil(
    http.StreamedResponse resp,
    String id,
    Duration timeout,
  ) async {
    final completer = Completer<Map<String, dynamic>?>();
    final dataLines = <String>[];
    late StreamSubscription sub;

    void finish(Map<String, dynamic>? value) {
      if (!completer.isCompleted) completer.complete(value);
      sub.cancel();
    }

    void flushEvent() {
      if (dataLines.isEmpty) return;
      final payload = dataLines.join('\n');
      dataLines.clear();
      if (payload.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(payload);
        final list = decoded is List ? decoded : [decoded];
        for (final m in list) {
          if (m is Map && m['id'] == id) {
            finish(Map<String, dynamic>.from(m));
            return;
          }
        }
      } catch (_) {
        // Not JSON, or a comment/keep-alive frame: ignore it.
      }
    }

    sub = resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.isEmpty) {
              flushEvent();
            } else if (line.startsWith('data:')) {
              dataLines.add(line.substring(5).trimLeft());
            }
            // `event:`, `id:`, `retry:` and `:` comments need no handling here.
          },
          onDone: () {
            flushEvent();
            finish(null);
          },
          onError: (e) {
            if (!completer.isCompleted) {
              completer.completeError(McpTransportError('读取流失败：$e'));
            }
            sub.cancel();
          },
          cancelOnError: true,
        );

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        throw McpTransportError('等待流式响应超时（${timeout.inSeconds}s）');
      },
    );
  }

  @override
  Future<void> close() async {
    // Politely tell the server the session is over; ignore the outcome.
    if (_sessionId != null) {
      try {
        await _client
            .delete(endpoint, headers: {'Mcp-Session-Id': _sessionId!})
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    _sessionId = null;
    _initialized = false;
    _client.close();
  }
}

// ---------------------------------------------------------------------------
// WebSocket (non-standard, kept for the app's own server)
// ---------------------------------------------------------------------------

class WebSocketTransport extends McpTransport {
  final Uri endpoint;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  int _nextId = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  WebSocketTransport(this.endpoint);

  @override
  Future<void> open() async {
    try {
      _channel = WebSocketChannel.connect(endpoint);
      await _channel!.ready.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      throw McpTransportError('连接超时(5s)，请检查服务器是否启动、IP 和端口是否正确');
    } catch (e) {
      throw McpTransportError('连接失败：$e');
    }

    _sub = _channel!.stream.listen(
      (data) {
        try {
          final msg = jsonDecode(data.toString());
          if (msg is! Map) return;
          final id = msg['id'];
          if (id is! String) return;
          final completer = _pending.remove(id);
          if (completer == null || completer.isCompleted) return;
          try {
            completer.complete(_unwrap(Map<String, dynamic>.from(msg)));
          } on McpTransportError catch (e) {
            completer.completeError(e);
          }
        } catch (_) {}
      },
      onError: (e) => _failAll(McpTransportError('连接中断：$e')),
      onDone: () => _failAll(McpTransportError('连接已关闭')),
    );
  }

  void _failAll(McpTransportError error) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final channel = _channel;
    if (channel == null) throw McpTransportError('尚未连接');

    final id = 'req_${++_nextId}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    channel.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw McpTransportError('请求超时（${timeout.inSeconds}s）：$method');
    }
  }

  @override
  Future<void> notify(String method, [Map<String, dynamic>? params]) async {
    _channel?.sink.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': method,
        if (params != null) 'params': params,
      }),
    );
  }

  @override
  Future<void> close() async {
    _failAll(McpTransportError('连接已关闭'));
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }
}

// ---------------------------------------------------------------------------

/// Turns a JSON-RPC reply into its `result`, or throws its `error`.
Map<String, dynamic> _unwrap(Map<String, dynamic> msg) {
  final error = msg['error'];
  if (error is Map) {
    throw McpTransportError(
      (error['message'] ?? '未知错误').toString(),
      code: error['code'] is int ? error['code'] as int : null,
    );
  }
  final result = msg['result'];
  if (result is Map) return Map<String, dynamic>.from(result);
  // A result may legitimately be absent (empty ack); treat it as empty.
  return <String, dynamic>{};
}

String _clip(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';
