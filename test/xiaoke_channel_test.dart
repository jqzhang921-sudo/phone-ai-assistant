import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/xiaoke_channel.dart';

/// 小克频道开在局域网上，这几条钉住两件事：
/// **连接码不对进不来**，以及**断线、没开 App 都不丢话**。
void main() {
  late Directory tmp;
  late XiaokeChannel channel;
  const token = 'secret-token';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xiaoke_test');
    XiaokeChannel.dirPath = tmp.path;
    channel = XiaokeChannel();
    await channel.start(port: 0, token: token);
  });

  tearDown(() async {
    await channel.stop();
    XiaokeChannel.dirPath = null;
    await tmp.delete(recursive: true);
  });

  Future<_Pc> connect(String withToken) =>
      _Pc.connect(channel.boundPort!, withToken);

  Future<void> eventually(bool Function() check) async {
    for (var i = 0; i < 100; i++) {
      if (check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('等了 2 秒还没到');
  }

  test('连接码不对：直接断开（4401），不算连上', () async {
    final pc = await connect('wrong-token');
    expect(await pc.closed.future.timeout(const Duration(seconds: 3)), 4401);
    expect(channel.online, isFalse);
  });

  test('电脑没连着时发的先存着；连上补发，收到 ack 才算送到', () async {
    await channel.send('在吗');
    expect(channel.messages.single.delivered, isFalse);

    final pc = await connect(token);
    expect((await pc.next())['type'], 'welcome');
    final msg = await pc.next();
    expect(msg['type'], 'msg');
    expect(msg['text'], '在吗');
    expect(channel.messages.single.delivered, isFalse);

    pc.send({'type': 'ack', 'id': msg['id']});
    await eventually(() => channel.messages.single.delivered);
  });

  test('连着的时候发：马上送过去', () async {
    final pc = await connect(token);
    await pc.next(); // welcome
    await eventually(() => channel.online);

    await channel.send('晚上吃什么');
    final msg = await pc.next();
    expect(msg['text'], '晚上吃什么');
  });

  test('小克回的：存下来再回 ack；同一条重发不会出现两遍', () async {
    final pc = await connect(token);
    await pc.next(); // welcome

    final reply = {
      'type': 'reply',
      'id': 'r1',
      'text': '吃面',
      'ts': '2026-09-15T12:00:00.000',
    };
    pc.send(reply);
    expect(await pc.next(), {'type': 'ack', 'id': 'r1'});

    pc.send(reply);
    expect(await pc.next(), {'type': 'ack', 'id': 'r1'});

    final fromXiaoke = channel.messages.where((m) => !m.fromMe);
    expect(fromXiaoke, hasLength(1));
    expect(fromXiaoke.single.text, '吃面');
  });

  test('电脑那边发的是世界标准时间：存成本地时间，不差八小时', () async {
    // Cleo 一眼看出来的：「咱们两个还有时差呢」。
    final pc = await connect(token);
    await pc.next(); // welcome
    pc.send({
      'type': 'reply',
      'id': 'r-utc',
      'text': '在',
      'ts': '2026-09-15T12:13:00.000Z',
    });
    await pc.next(); // ack

    final got = channel.messages.single.ts;
    expect(got.isUtc, isFalse);
    expect(
      got.difference(DateTime.parse('2026-09-15T12:13:00.000Z')),
      Duration.zero,
    );
  });

  test('电脑那边的心跳：ping 了就回 pong', () async {
    // 电脑那边靠这个发现死连接，不回的话它每 45 秒就会断一次重连。
    final pc = await connect(token);
    await pc.next(); // welcome
    pc.send({'type': 'ping'});
    expect(await pc.next(), {'type': 'pong'});
  });

  test('关掉重开：聊天记录还在', () async {
    final pc = await connect(token);
    await pc.next(); // welcome
    await channel.send('我去睡了');
    pc.send({'type': 'reply', 'id': 'r2', 'text': '晚安', 'ts': ''});
    await pc.next(); // msg
    await pc.next(); // ack
    await channel.stop();

    final reopened = XiaokeChannel();
    await reopened.load();
    expect(reopened.messages.map((m) => m.text), ['我去睡了', '晚安']);
  });

  test('电脑那边重连：新连接顶掉旧的', () async {
    final first = await connect(token);
    await first.next(); // welcome
    final second = await connect(token);
    await second.next(); // welcome

    expect(await first.closed.future.timeout(const Duration(seconds: 3)), 4000);
    expect(channel.online, isTrue);
  });
}

/// 电脑那边（xiaoke-channel）的替身：连上、打招呼，把收到的帧排成队。
class _Pc {
  _Pc(this.ws) {
    ws.listen(
      (data) => _frames.add(jsonDecode('$data') as Map<String, dynamic>),
      onDone: () {
        _frames.close();
        if (!closed.isCompleted) closed.complete(ws.closeCode);
      },
    );
  }

  final WebSocket ws;
  final _frames = StreamController<Map<String, dynamic>>();
  late final _iterator = StreamIterator(_frames.stream);
  final closed = Completer<int?>();

  static Future<_Pc> connect(int port, String token) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:$port${XiaokeChannel.path}',
    );
    final pc = _Pc(ws);
    pc.send({'type': 'hello', 'token': token});
    return pc;
  }

  void send(Map<String, dynamic> frame) => ws.add(jsonEncode(frame));

  Future<Map<String, dynamic>> next() async {
    final has = await _iterator.moveNext().timeout(const Duration(seconds: 3));
    if (!has) throw StateError('连接已经断了');
    return _iterator.current;
  }
}
