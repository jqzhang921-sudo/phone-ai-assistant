import 'dart:io';
import 'dart:ui' as ui;
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

/// 背景信息：自定义图片路径 + 预设 + 前景色是否需要深色（可读性自适应）。
class BackgroundProvider extends ChangeNotifier {
  String? _path;
  String _preset = 'none';
  bool? _darkForeground; // null = 跟随主题

  String? get path => _path;
  String get preset => _preset;

  /// 背景偏亮时返回 true（文字用深色），偏暗返回 false（文字用浅色）。
  bool? get darkForeground => _darkForeground;

  Future<void> update(String? path, String preset) async {
    _path = path;
    _preset = preset;
    if (path != null) {
      final avg = await _averageColor(path);
      _darkForeground = avg == null || avg.computeLuminance() > 0.5;
    } else if (preset == 'dark') {
      _darkForeground = false;
    } else if (preset == 'light') {
      _darkForeground = true;
    } else {
      _darkForeground = null;
    }
    notifyListeners();
  }

  Future<ui.Color?> _averageColor(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32,
        targetHeight: 32,
      );
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null) return null;
      var r = 0, g = 0, b = 0;
      final n = data.lengthInBytes ~/ 4;
      for (var i = 0; i < n; i++) {
        r += data.getUint8(i * 4);
        g += data.getUint8(i * 4 + 1);
        b += data.getUint8(i * 4 + 2);
      }
      return ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
    } catch (_) {
      return null;
    }
  }
}
