import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../config/settings.dart';
import '../models/musing_entry.dart';
import 'storage_service.dart';
import '../models/mcp_tool.dart';
import 'ai_client.dart';
import 'external_mcp_client.dart';
import 'external_mcp_service.dart';
import 'mcp_server.dart';

// 全局设置 Provider：改动即时通知（主题字体切换等）
class SettingsProvider extends ChangeNotifier {
  AppSettings? _settings;
  AppSettings? get settings => _settings;

  void setSettings(AppSettings s) {
    _settings = s;
    notifyListeners();
  }

  Future<void> setTitleSerif(bool v) async {
    final s = _settings;
    if (s == null) return;
    s.titleSerif = v;
    await s.save();
    notifyListeners();
  }

  /// 深浅色。themeMode 一直存在 settings 里、main.dart 也读了，
  /// 但之前设置页没有任何入口能改它——整套深色主题只有系统切深色才看得到。
  Future<void> setThemeMode(ThemeMode m) async {
    final s = _settings;
    if (s == null) return;
    s.themeMode = m;
    await s.save();
    notifyListeners();
  }
}

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
    // 只有**真的贴了背景图**才需要覆盖前景色：图是什么亮度只有这里知道，
    // 主题猜不到。没有图的时候一律回 null，交给主题。
    //
    // 原来 preset 'dark' / 'light' 也会在这里钉死前景色。那是配套「预设写死
    // 底色」用的，而那套底色早就删了（见 home_shell 里的注释：明暗统一归主题
    // 管），前景色的覆盖却留了下来——预设不再画任何背景，却还在强行指定字色。
    //
    // 后果：选过深色预设之后切浅色主题，四个页面（主页 / 聊天 / 书架 / 栖息）
    // 的标题栏全是白字压奶白底，几乎看不见。2026-08-27 实测复现。
    if (path != null) {
      final avg = await _averageColor(path);
      _darkForeground = avg == null || avg.computeLuminance() > 0.5;
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

/// 收藏的话。
///
/// 收藏状态要在每条气泡上显示，逐条去 SharedPreferences 查一遍太浪费；
/// 这里一次读全，之后只在内存里判断，改动时才落盘。
class FavoritesProvider extends ChangeNotifier {
  List<MusingEntry> _entries = [];
  Set<String> _messageIds = {};

  List<MusingEntry> get entries => _entries;

  bool isFavorited(String messageId) => _messageIds.contains(messageId);

  Future<void> load() async {
    _entries = await StorageService.listFavoritedMusings();
    _messageIds = {
      for (final e in _entries)
        if (e.messageId != null) e.messageId!,
    };
    notifyListeners();
  }

  Future<void> add(MusingEntry entry) async {
    await StorageService.addFavoritedMusing(entry);
    await load();
  }

  Future<void> remove(String id) async {
    await StorageService.removeFavoritedMusing(id);
    await load();
  }

  /// 按消息 id 取消收藏。返回被删掉的那条，方便调用方给「撤销」。
  Future<MusingEntry?> removeByMessageId(String messageId) async {
    final match = _entries.where((e) => e.messageId == messageId).firstOrNull;
    if (match == null) return null;
    await remove(match.id);
    return match;
  }
}
