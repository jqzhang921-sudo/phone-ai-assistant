import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// agent-bridge 连接配置。
class PcBridgeConfig {
  final String url;
  final String token;
  final String agent; // 'codex' | 'claude'

  const PcBridgeConfig({
    required this.url,
    required this.token,
    required this.agent,
  });
}

/// 桥接事件。
sealed class PcBridgeEvent {
  const PcBridgeEvent();
}

class PcBridgeText extends PcBridgeEvent {
  final String text;
  const PcBridgeText(this.text);
}

class PcBridgeStatus extends PcBridgeEvent {
  final String message;
  const PcBridgeStatus(this.message);
}

class PcBridgeDone extends PcBridgeEvent {
  final int? exitCode;
  const PcBridgeDone(this.exitCode);
}

class PcBridgeError extends PcBridgeEvent {
  final String message;
  const PcBridgeError(this.message);
}

/// 配置读写。
class PcBridgeStorage {
  static const _kUrl = 'pc_bridge_url';
  static const _kAgent = 'pc_bridge_agent';
  static const _kToken = 'pc_bridge_token';
  static final _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<PcBridgeConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kUrl) ?? 'ws://100.79.248.111:8787';
    final agent = prefs.getString(_kAgent) ?? 'codex';
    final token = await _secure.read(key: _kToken) ?? '';
    return PcBridgeConfig(url: url, token: token, agent: agent);
  }

  static Future<void> save(PcBridgeConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, config.url);
    await prefs.setString(_kAgent, config.agent);
    await _secure.write(key: _kToken, value: config.token);
  }
}

/// 一次性的桥接会话：连接 -> 鉴权 -> 发消息 -> 流式接收。
class PcBridgeChat {
  WebSocketChannel? _channel;
  StreamController<PcBridgeEvent>? _controller;
  bool _closed = false;

  Future<Stream<PcBridgeEvent>> start(PcBridgeConfig config) async {
    _controller = StreamController<PcBridgeEvent>();
    _closed = false;
    final channel = WebSocketChannel.connect(Uri.parse(config.url));
    _channel = channel;

    channel.stream.listen(
      (data) {
        final s = data is String ? data : utf8.decode(data as List<int>);
        _handleLine(s, config);
      },
      onError: (Object e) {
        if (!_closed) {
          _controller?.add(PcBridgeError('连接出错: $e'));
          _controller?.close();
        }
      },
      onDone: () {
        if (!_closed) {
          _controller?.add(const PcBridgeDone(null));
          _controller?.close();
        }
      },
    );

    channel.sink.add(jsonEncode({'type': 'auth', 'token': config.token}));
    return _controller!.stream;
  }

  void sendMessage(PcBridgeConfig config, String message) {
    _channel?.sink.add(
      jsonEncode({'type': 'chat', 'agent': config.agent, 'message': message}),
    );
  }

  void cancel() {
    _channel?.sink.add(jsonEncode({'type': 'cancel'}));
  }

  void _handleLine(String raw, PcBridgeConfig config) {
    final line = raw.trim();
    if (line.isEmpty) return;

    dynamic j;
    try {
      j = jsonDecode(line);
    } catch (_) {
      _controller?.add(PcBridgeText(line));
      return;
    }
    if (j is! Map<String, dynamic>) {
      _controller?.add(PcBridgeText(line));
      return;
    }

    final type = j['type'];
    switch (type) {
      case 'auth_result':
        _controller?.add(
          j['ok'] == true
              ? const PcBridgeStatus('已连接电脑')
              : const PcBridgeError('鉴权失败：token 不对'),
        );
        break;
      case 'started':
        _controller?.add(const PcBridgeStatus('任务开始…'));
        break;
      case 'done':
        _controller?.add(PcBridgeDone((j['exitCode'] as num?)?.toInt()));
        break;
      case 'cancelled':
        _controller?.add(const PcBridgeStatus('已取消'));
        break;
      case 'stderr':
        final t = j['text'] as String?;
        // codex 启动时会打印一行提示噪音，忽略掉
        if (t != null &&
            t.trim().isNotEmpty &&
            !t.contains('Reading additional input from stdin')) {
          _controller?.add(PcBridgeText(t.trim()));
        }
        break;
      case 'error':
        _controller?.add(PcBridgeError((j['message'] as String?) ?? '未知错误'));
        break;
      default:
        final text = _extractText(j);
        if (text != null && text.isNotEmpty) {
          _controller?.add(PcBridgeText(text));
        }
    }
  }

  /// 从 codex / claude 的 JSON 行里尽量抠出可读文本。
  String? _extractText(Map<String, dynamic> j) {
    String? fromList(dynamic v) {
      if (v is! List) return null;
      final sb = StringBuffer();
      for (final e in v) {
        if (e is Map) {
          final t = e['text'];
          if (t is String && t.isNotEmpty) sb.writeln(t);
          if (e['type'] == 'tool_use' && e['name'] is String) {
            sb.writeln('［调用工具：${e['name']}］');
          }
        }
      }
      final s = sb.toString().trim();
      return s.isEmpty ? null : s;
    }

    final msg = j['message'];
    if (msg is Map) {
      final t = fromList(msg['content']);
      if (t != null) return t;
    }
    // codex exec --json 的 item.completed 结构
    final item = j['item'];
    if (item is Map) {
      final it = item['text'];
      if (it is String && it.isNotEmpty) return it;
      final ic = fromList(item['content']);
      if (ic != null) return ic;
    }
    final c = fromList(j['content']);
    if (c != null) return c;
    final delta = j['delta'];
    if (delta is Map) {
      final d = delta['content'];
      if (d is String && d.isNotEmpty) return d;
    }
    final text = j['text'];
    if (text is String && text.isNotEmpty) return text;
    return null;
  }

  void dispose() {
    _closed = true;
    _channel?.sink.close();
    _controller?.close();
  }
}
