import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/mcp_tool.dart';
import 'external_mcp_service.dart';

class ExternalMcpClient {
  final ExternalMcpServer config;
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _connected = false;
  final List<McpTool> _tools = [];
  int _msgId = 0;
  final Map<String, Completer<Map<String, dynamic>?>> _pending = {};

  String? _lastError;

  bool get connected => _connected;
  String? get lastError => _lastError;
  List<McpTool> get tools => List.unmodifiable(_tools);

  ExternalMcpClient({required this.config});

  Future<bool> connect() async {
    try {
      final uri = Uri.parse(config.url);

      // Connection timeout using a race
      try {
        _channel = WebSocketChannel.connect(uri);
        await _channel!.ready.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _lastError = '连接超时(5s)，请检查服务器是否启动、IP和端口是否正确';
        _connected = false;
        return false;
      }

      // Single stream listener for all responses
      _subscription = _channel!.stream.listen((data) {
        try {
          final response = jsonDecode(data.toString()) as Map<String, dynamic>;
          final id = response['id'] as String?;
          if (id != null && _pending.containsKey(id)) {
            final completer = _pending.remove(id);
            if (completer != null) {
              if (response['result'] != null) {
                completer.complete(
                    Map<String, dynamic>.from(response['result']));
              } else {
                completer.complete(null);
              }
            }
          }
        } catch (_) {}
      });

      // Send initialize
      final result = await _sendRequest('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {
          'name': 'phone-ai-assistant',
          'version': '1.0.0',
        },
      });

      if (result != null) {
        _connected = true;
        // List tools
        final toolsResult = await _sendRequest('tools/list');
        if (toolsResult != null && toolsResult['tools'] != null) {
          for (final t in toolsResult['tools']) {
            _tools.add(McpTool.fromJson(Map<String, dynamic>.from(t)));
          }
        }
        return true;
      }
      return false;
    } catch (e) {
      _lastError = '连接失败: $e';
      _connected = false;
      return false;
    }
  }

  Future<Map<String, dynamic>?> _sendRequest(
      String method, [Map<String, dynamic>? params]) async {
    if (_channel == null) return null;
    final id = 'req_${++_msgId}';
    final completer = Completer<Map<String, dynamic>?>();
    _pending[id] = completer;

    final request = {
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      'id': id,
    };

    _channel!.sink.add(jsonEncode(request));

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _pending.remove(id);
      return null;
    }
  }

  Future<Map<String, dynamic>> callTool(
      String name, Map<String, dynamic> args) async {
    final result = await _sendRequest('tools/call', {
      'name': name,
      'arguments': args,
    });
    return result ?? {'success': false, 'error': '工具调用超时或无响应'};
  }

  Future<void> disconnect() async {
    _connected = false;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
    _tools.clear();
    _pending.clear();
  }

  void dispose() {
    disconnect();
  }
}
