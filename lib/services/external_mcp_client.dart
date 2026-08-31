import 'dart:async';

import '../models/mcp_tool.dart';
import 'external_mcp_service.dart';
import 'mcp_transport.dart';

/// Talks to one external MCP server.
///
/// The wire format is the same either way; only the transport differs, so
/// everything below is written against [McpTransport] and works for both
/// Streamable HTTP endpoints and the app's own WebSocket server.
class ExternalMcpClient {
  final ExternalMcpServer config;

  McpTransport? _transport;
  bool _connected = false;
  final List<McpTool> _tools = [];
  String? _lastError;
  String? _serverName;
  int _skippedTools = 0;

  bool get connected => _connected;
  String? get lastError => _lastError;
  String? get serverName => _serverName;
  List<McpTool> get tools => List.unmodifiable(_tools);

  /// 这台服务器上有几个工具没能解析。正常是 0；不是 0 的话，界面上那个
  /// 「N 工具」会比服务器实际给的少，得让人看得见差在哪，别让它无声消失。
  int get skippedTools => _skippedTools;

  ExternalMcpClient({required this.config});

  Future<bool> connect() async {
    _lastError = null;
    _tools.clear();
    _skippedTools = 0;

    try {
      final transport = createTransport(config.url, token: config.token);
      _transport = transport;
      await transport.open();

      final init = await transport.request('initialize', {
        'protocolVersion': kMcpProtocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'phone-ai-assistant', 'version': '1.0.0'},
      }, const Duration(seconds: 15));

      final info = init['serverInfo'];
      if (info is Map && info['name'] != null) {
        _serverName = info['name'].toString();
      }

      // Required second half of the handshake. Strict servers reject every
      // later request until they have seen it.
      transport.onInitialized();
      await transport.notify('notifications/initialized');

      final listed = await transport.request(
        'tools/list',
        null,
        const Duration(seconds: 15),
      );
      // 逐个 try：解析不了的那一个跳过就行，不能让它把整台服务器拖下水。
      // 外层那个 catch 是给「连不上」准备的，一个畸形工具走到那里，症状会变成
      // 「连接失败」——看着像是服务器挂了，其实只是某个工具字段不全。
      final list = listed['tools'];
      if (list is List) {
        for (final t in list) {
          if (t is! Map) continue;
          try {
            _tools.add(McpTool.fromJson(Map<String, dynamic>.from(t)));
          } catch (_) {
            _skippedTools++;
          }
        }
      }

      _connected = true;
      return true;
    } on McpTransportError catch (e) {
      _lastError = e.message;
      await _cleanup();
      return false;
    } catch (e) {
      _lastError = '连接失败：$e';
      await _cleanup();
      return false;
    }
  }

  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final transport = _transport;
    if (transport == null || !_connected) {
      return {'success': false, 'error': '未连接到 ${config.name}'};
    }
    try {
      return await transport.request('tools/call', {
        'name': name,
        'arguments': args,
      }, const Duration(seconds: 60));
    } on McpTransportError catch (e) {
      return {'success': false, 'error': e.message};
    } catch (e) {
      return {'success': false, 'error': '工具调用失败：$e'};
    }
  }

  Future<void> _cleanup() async {
    _connected = false;
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      try {
        await transport.close();
      } catch (_) {}
    }
  }

  Future<void> disconnect() async {
    await _cleanup();
    _tools.clear();
  }

  void dispose() {
    disconnect();
  }
}
