import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// 小克频道里的一条消息。
class XiaokeMessage {
  XiaokeMessage({
    required this.id,
    required this.fromMe,
    required this.text,
    required this.ts,
    this.delivered = false,
  });

  final String id;

  /// true = Cleo 发的；false = 小克回的。
  final bool fromMe;
  final String text;
  final DateTime ts;

  /// Cleo 发的那条送到电脑那边没有——收到 ack 才算。小克回的一律 true。
  bool delivered;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromMe': fromMe,
    'text': text,
    'ts': ts.toIso8601String(),
    'delivered': delivered,
  };

  factory XiaokeMessage.fromJson(Map<String, dynamic> j) => XiaokeMessage(
    id: '${j['id']}',
    fromMe: j['fromMe'] == true,
    text: '${j['text'] ?? ''}',
    ts: DateTime.tryParse('${j['ts']}')?.toLocal() ?? DateTime.now(),
    delivered: j['delivered'] == true,
  );
}

/// 「小克」页面 ↔ 电脑上正在跑的 Claude Code 会话。
///
/// ## 这不是聊天模型
///
/// 这里发的消息**不经过 App 里配的模型**：没有人设、没有记忆、没有工具。
/// App 只是个窗口，消息原样送到电脑那边那个会话里，回的话原样显示——
/// 跟 Cleo 在 Telegram 里找小克是一回事。她要的就是「不被 App 里的提示词干扰」。
///
/// ## 为什么是手机开服务、电脑来连
///
/// 电脑那边跑在 WSL 里，WSL 是 NAT，手机连不进去；反过来 WSL 连得到手机。
/// 所以这里开一个 WebSocket（[defaultPort]），电脑那边的 `xiaoke-channel`
/// 当客户端连过来。**第一帧必须带对连接码**，不对直接断——这个端口开在
/// 局域网上，连接码就是钥匙。
///
/// 协议写在 `xiaoke-channel/server.ts` 顶上。要点：两边没收到 ack 的都在下次
/// 连上时重发，按 id 去重，所以断网、App 被杀、电脑重启都不丢话。
class XiaokeChannel extends ChangeNotifier {
  XiaokeChannel();

  static final instance = XiaokeChannel();

  /// 聊天记录放哪。[StorageService.init] 里设。
  static String? dirPath;

  static const defaultPort = 8766;
  static const path = '/xiaoke';

  static const _tokenKey = 'xiaoke_channel_token';
  static final _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final List<XiaokeMessage> messages = [];

  HttpServer? _server;
  WebSocket? _peer;
  String? _token;
  bool _loaded = false;
  Future<void> _saving = Future.value();

  /// 电脑那边连着没有。
  bool get online => _peer != null;
  int? get boundPort => _server?.port;
  String? get token => _token;

  /// 开服务。重复调没事。[token] 只给测试传——正常从安全存储里取，没有就生成一个。
  Future<void> start({int port = defaultPort, String? token}) async {
    if (_server != null) return;
    await load();
    _token = token ?? await _loadOrCreateToken();
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } catch (e) {
      debugPrint('[xiaoke] 端口 $port 开不了：$e');
      return;
    }
    _server!.listen(
      _onRequest,
      onError: (Object e) => debugPrint('[xiaoke] 服务出错：$e'),
    );
  }

  Future<void> stop() async {
    final peer = _peer;
    _peer = null;
    await peer?.close();
    await _server?.close(force: true);
    _server = null;
    await _saving;
    notifyListeners();
  }

  /// 读聊天记录。读过不重复读。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final file = _file;
    if (file == null || !await file.exists()) return;
    try {
      final list = jsonDecode(await file.readAsString()) as List;
      messages
        ..clear()
        ..addAll(
          list.map(
            (e) => XiaokeMessage.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
      notifyListeners();
    } catch (e) {
      debugPrint('[xiaoke] 聊天记录读不出来：$e');
    }
  }

  /// 发一条。电脑那边没连着就先存着，连上补发。
  Future<void> send(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await load();
    final m = XiaokeMessage(
      id: const Uuid().v4(),
      fromMe: true,
      text: t,
      ts: DateTime.now(),
    );
    messages.add(m);
    notifyListeners();
    await _save();
    if (_peer != null) _sendMsg(m);
  }

  /// 换一个连接码。旧的立刻失效，连着的也断掉。
  Future<void> resetToken() async {
    _token = _newToken();
    try {
      await _secure.write(key: _tokenKey, value: _token);
    } catch (e) {
      debugPrint('[xiaoke] 连接码存不进去：$e');
    }
    final peer = _peer;
    _peer = null;
    await peer?.close(4401, 'token reset');
    notifyListeners();
  }

  /// 手机在局域网里的地址，给「连接信息」显示。
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses)
            if (!a.isLoopback) a.address,
      ];
    } catch (_) {
      return const [];
    }
  }

  // ───────────────────────── 连接 ─────────────────────────

  Future<void> _onRequest(HttpRequest request) async {
    if (request.uri.path != path ||
        !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(request);
    var authed = false;
    // 连上了却一直不打招呼的，5 秒后断掉，别占着。
    final timer = Timer(const Duration(seconds: 5), () {
      if (!authed) ws.close(4401, 'hello timeout');
    });

    ws.listen(
      (data) async {
        final Map<String, dynamic> frame;
        try {
          frame = jsonDecode('$data') as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        if (!authed) {
          if (frame['type'] == 'hello' && _sameToken('${frame['token']}')) {
            authed = true;
            timer.cancel();
            _adopt(ws);
          } else {
            ws.close(4401, 'bad token');
          }
          return;
        }
        await _onFrame(ws, frame);
      },
      onDone: () {
        timer.cancel();
        if (identical(_peer, ws)) {
          _peer = null;
          notifyListeners();
        }
      },
      onError: (Object _) {},
    );
  }

  /// 认下这个连接。新连上的顶掉旧的——电脑那边重启过，旧连接就是死的。
  void _adopt(WebSocket ws) {
    final old = _peer;
    _peer = ws;
    old?.close(4000, 'replaced');
    ws.pingInterval = const Duration(seconds: 20);
    _sendFrame({'type': 'welcome'});
    for (final m in messages.where((m) => m.fromMe && !m.delivered)) {
      _sendMsg(m);
    }
    notifyListeners();
  }

  Future<void> _onFrame(WebSocket ws, Map<String, dynamic> frame) async {
    if (!identical(ws, _peer)) return;
    switch (frame['type']) {
      case 'ack':
        final id = '${frame['id']}';
        final hit = messages.where((m) => m.id == id && m.fromMe).firstOrNull;
        if (hit != null && !hit.delivered) {
          hit.delivered = true;
          notifyListeners();
          await _save();
        }
      case 'reply':
        final id = '${frame['id'] ?? ''}';
        final text = '${frame['text'] ?? ''}';
        if (id.isEmpty) return;
        // 重发的同一条只回 ack，不再显示一遍。
        if (!messages.any((m) => m.id == id) && text.trim().isNotEmpty) {
          messages.add(
            XiaokeMessage(
              id: id,
              fromMe: false,
              text: text,
              // ⚠️ 必须 toLocal()。电脑那边发的是世界标准时间（带 Z），
              // 直接拿去显示就差八小时——Cleo 一眼看出来了：「咱们两个还有时差呢」。
              ts:
                  DateTime.tryParse('${frame['ts']}')?.toLocal() ??
                  DateTime.now(),
              delivered: true,
            ),
          );
          notifyListeners();
          await _save();
        }
        // 存下来了才回 ack：没存住就让那边下次再发。
        _sendFrame({'type': 'ack', 'id': id});
    }
  }

  void _sendMsg(XiaokeMessage m) => _sendFrame({
    'type': 'msg',
    'id': m.id,
    'text': m.text,
    'ts': m.ts.toIso8601String(),
  });

  void _sendFrame(Map<String, dynamic> frame) {
    try {
      _peer?.add(jsonEncode(frame));
    } catch (e) {
      debugPrint('[xiaoke] 发不出去：$e');
    }
  }

  // ───────────────────────── 连接码 ─────────────────────────

  Future<String> _loadOrCreateToken() async {
    try {
      final t = await _secure.read(key: _tokenKey);
      if (t != null && t.isNotEmpty) return t;
    } catch (e) {
      debugPrint('[xiaoke] 连接码读不出来，重新生成：$e');
    }
    final t = _newToken();
    try {
      await _secure.write(key: _tokenKey, value: t);
    } catch (_) {}
    return t;
  }

  static String _newToken() {
    final r = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// 逐字节比完再说对不对，别在第一个不同的字节就返回。
  bool _sameToken(String given) {
    final want = _token;
    if (want == null || given.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= want.codeUnitAt(i) ^ given.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ───────────────────────── 落盘 ─────────────────────────

  File? get _file {
    final dir = dirPath;
    return dir == null ? null : File('$dir/messages.json');
  }

  /// 串行写：ack 和新消息可能同时要存，一起写同一个 .tmp 会互相踩。
  Future<void> _save() =>
      _saving = _saving
          .then((_) => _writeNow())
          .catchError((Object e) => debugPrint('[xiaoke] 聊天记录存不进去：$e'));

  Future<void> _writeNow() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final m in messages) m.toJson()]));
    await tmp.rename(file.path);
  }
}
