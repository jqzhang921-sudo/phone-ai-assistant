import 'dart:io';
import 'dart:math' as math;
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
      _stats = await _analyze(path);
      final avg = _stats?.average;
      _darkForeground = avg == null || avg.computeLuminance() > 0.5;
    } else {
      _stats = null;
      _darkForeground = null;
    }
    notifyListeners();
  }

  /// 从背景图里读出来的三个值。一次采样全算完，别为了其中一个再解一遍图。
  ///
  /// [average] 只用来定前景色深浅（老用法）。另外两个是玻璃主题要的：
  /// [accent] 让强调色跟着背景走，[busyness] 决定玻璃要多厚才压得住。
  ({ui.Color average, ui.Color? accent, double busyness})? _stats;

  /// 背景图给出的强调色。没有背景图、或图本身没有明确色相时是 null，
  /// 调用方回落到主题里那个棕色。
  ui.Color? get backgroundAccent => _stats?.accent;

  /// 背景「花不花」：0 = 一整块纯色，1 = 到处都是细节。
  ///
  /// 玻璃卡片的不透明度按它走——渐变底可以很通透，有雨丝伞骨的图就得厚一点，
  /// 否则文字压在细节上读不清。没有背景图时返回 0（那时候也用不上）。
  double get backgroundBusyness => _stats?.busyness ?? 0;

  /// 解一次 32×32，把平均色、强调色、花乱程度一起算出来。
  Future<({ui.Color average, ui.Color? accent, double busyness})?> _analyze(
    String path,
  ) async {
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

      final n = data.lengthInBytes ~/ 4;
      var r = 0, g = 0, b = 0;
      // 色相用向量平均，不能直接对角度取平均——359° 和 1° 的平均是 180°，
      // 那是完全相反的颜色。按饱和度加权：灰的像素对「这张图什么色」没有发言权。
      var hx = 0.0, hy = 0.0, satWeight = 0.0;
      final lums = <double>[];

      for (var i = 0; i < n; i++) {
        final pr = data.getUint8(i * 4);
        final pg = data.getUint8(i * 4 + 1);
        final pb = data.getUint8(i * 4 + 2);
        r += pr;
        g += pg;
        b += pb;

        final hsv = HSVColor.fromColor(ui.Color.fromARGB(255, pr, pg, pb));
        final w = hsv.saturation;
        final rad = hsv.hue * math.pi / 180;
        hx += math.cos(rad) * w;
        hy += math.sin(rad) * w;
        satWeight += w;

        lums.add((0.2126 * pr + 0.7152 * pg + 0.0722 * pb) / 255);
      }

      final average = ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);

      // 亮度的标准差就是「花不花」：渐变底几乎没有起伏，带图案的会明显跳。
      // 0.22 是把七张实际壁纸跑过之后定的分界——渐变都在 0.05 以下，
      // 有雨伞那张 0.18 上下，兔子那张最花。
      final mean = lums.reduce((a, c) => a + c) / lums.length;
      final variance =
          lums.map((l) => (l - mean) * (l - mean)).reduce((a, c) => a + c) /
          lums.length;
      final busyness = (math.sqrt(variance) / 0.22).clamp(0.0, 1.0);

      // 真的没有色相可言（近乎黑白）才放弃，回落到徽标棕。
      //
      // ⚠️ 门槛原来是 0.06，把「淡」和「灰」当成了一回事——Cleo 那张粉白渐变
      // 壁纸有明确的粉色相，只是饱和度低，结果过不了线，置顶卡片在粉色背景上
      // 冒出一块棕。淡不等于没有颜色。
      final avgSat = satWeight / n;
      ui.Color? accent;
      if (avgSat > 0.02) {
        var hue = math.atan2(hy, hx) * 180 / math.pi;
        if (hue < 0) hue += 360;
        // 只借**色相**，明度锁死——这样换任何背景，强调色的视觉重量都一样，
        // 不会有的图上跳出来、有的图上看不见。
        //
        // 饱和度跟着原图走一点：从一张淡粉壁纸里取出一块艳粉，会比棕色更突兀。
        // 上限 0.35（徽标棕的档位），下限 0.14——再低就看不出是个颜色了。
        final sat = (avgSat * 2.2).clamp(0.14, 0.35);
        accent = HSVColor.fromAHSV(1, hue, sat, 0.85).toColor();
      }

      return (average: average, accent: accent, busyness: busyness);
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
