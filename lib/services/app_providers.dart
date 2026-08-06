import 'package:flutter/foundation.dart';
import '../models/mcp_tool.dart';
import 'ai_client.dart';
import 'external_mcp_client.dart';
import 'external_mcp_service.dart';
import 'mcp_server.dart';

// 全局状态 Provider
class AiClientProvider extends ChangeNotifier {
  AiClient? _currentClient;
  AiClient? get currentClient => _currentClient;

  void setClient(AiClient? client) {
    _currentClient = client;
    notifyListeners();
  }
}

class McpServerProvider extends ChangeNotifier {
  final McpServer _server = McpServer();
  McpServer get server => _server;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  void markInitialized() {
    _isInitialized = true;
    notifyListeners();
  }
}

class ExternalMcpProvider extends ChangeNotifier {
  final List<ExternalMcpClient> _clients = [];
  List<ExternalMcpClient> get clients => List.unmodifiable(_clients);
  bool _connecting = false;
  bool get connecting => _connecting;

  List<McpTool> get allExternalTools =>
      _clients.where((c) => c.connected).expand((c) => c.tools).toList();

  /// Returns null on success, or an error message string on failure.
  Future<String?> connectTo(ExternalMcpServer config) async {
    _clients.removeWhere((c) => c.config.url == config.url);
    _connecting = true;
    notifyListeners();

    final client = ExternalMcpClient(config: config);
    final ok = await client.connect();
    _connecting = false;

    if (ok) {
      _clients.add(client);
      notifyListeners();
      return null;
    } else {
      notifyListeners();
      return client.lastError ?? '连接失败，请检查服务器是否运行';
    }
  }

  Future<void> disconnect(String url) async {
    final client = _clients.where((c) => c.config.url == url).firstOrNull;
    if (client != null) {
      await client.disconnect();
      _clients.remove(client);
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> callExternalTool(
    String url,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final client = _clients.where((c) => c.config.url == url).firstOrNull;
    if (client == null) {
      return {'success': false, 'error': '未连接到 $url'};
    }
    return client.callTool(toolName, args);
  }

  void reconnectToEnabled(List<ExternalMcpServer> configs) async {
    for (final cfg in configs.where((c) => c.enabled)) {
      // Skip if already connected
      if (_clients.any((c) => c.config.url == cfg.url)) continue;
      await Future.delayed(const Duration(milliseconds: 500));
      await connectTo(cfg);
    }
    // Remove connections to servers no longer in config
    final urls = configs.map((c) => c.url).toList();
    for (final client in _clients.toList()) {
      if (!urls.contains(client.config.url)) {
        await client.disconnect();
        _clients.remove(client);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final c in _clients) {
      c.disconnect();
    }
    super.dispose();
  }
}
