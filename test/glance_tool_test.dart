import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/services/phone_tools/glance_tool.dart';
import 'package:phone_ai_assistant/services/screen_glance.dart';

/// 聊天里「你看看」：悬浮窗马上看，全屏等她切出去再看。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('screen_glance');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final webp = Uint8List.fromList([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]);
  final defaults = (
    floating: GlanceWindow.floating,
    wait: GlanceTool.maxWait,
    poll: GlanceTool.poll,
  );

  late Directory tmp;
  late List<MethodCall> calls;

  /// [checks] 按顺序回给每次 check；用完了就一直回最后一个。
  void phone({
    List<Map<String, dynamic>> checks = const [
      {'package': 'com.xingin.xhs', 'label': '小红书'},
    ],
  }) {
    var i = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'check') {
        return checks[i < checks.length ? i++ : checks.length - 1];
      }
      return {'package': 'com.xingin.xhs', 'label': '小红书', 'bytes': webp};
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ScreenGlance.setAllowed(true);
    tmp = await Directory.systemTemp.createTemp('glance_tool');
    ChatImages.dirPath = tmp.path;
    calls = [];
    GlanceTool.maxWait = const Duration(milliseconds: 200);
    GlanceTool.poll = const Duration(milliseconds: 10);
    GlanceWindow.floating = () => false;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    GlanceWindow.floating = defaults.floating;
    GlanceTool.maxWait = defaults.wait;
    GlanceTool.poll = defaults.poll;
    ChatImages.dirPath = null;
    await tmp.delete(recursive: true);
  });

  Map<String, dynamic> argsOf(String method) =>
      Map<String, dynamic>.from(
        calls.lastWhere((c) => c.method == method).arguments as Map,
      );

  test('她没允许：看不了，也不去碰系统', () async {
    await ScreenGlance.setAllowed(false);
    phone();
    final r = await GlanceTool.execute({});
    expect(r['success'], isFalse);
    expect(r['error'], contains('没开'));
    expect(calls, isEmpty);
  });

  test('悬浮窗：不等，马上截，而且允许「前台是我们自己」', () async {
    GlanceWindow.floating = () => true;
    phone();
    final r = await GlanceTool.execute({});

    expect(r['success'], isTrue);
    expect(r['app'], '小红书');
    expect(calls.map((c) => c.method), ['capture']);
    expect(argsOf('capture')['allowInApp'], isTrue);
    expect(ChatImages.fileOf(r['image'] as String)!.existsSync(), isTrue);
  });

  test('全屏：等她切出去再截', () async {
    phone(
      checks: [
        {'miss': 'in_app'},
        {'miss': 'in_app'},
        {'package': 'com.xingin.xhs', 'label': '小红书'},
      ],
    );
    final r = await GlanceTool.execute({});

    expect(r['success'], isTrue);
    expect(calls.where((c) => c.method == 'check'), hasLength(3));
    expect(argsOf('capture')['allowInApp'], isFalse);
  });

  test('全屏一直不切出去：到点放弃，不截', () async {
    phone(checks: [
      {'miss': 'in_app'},
    ]);
    final r = await GlanceTool.execute({});

    expect(r['success'], isFalse);
    expect(r['error'], contains('没切出去'));
    expect(calls.where((c) => c.method == 'capture'), isEmpty);
  });

  test('等的时候发现锁屏了：直接说为什么没看成', () async {
    phone(checks: [
      {'miss': 'locked'},
    ]);
    final r = await GlanceTool.execute({});

    expect(r['success'], isFalse);
    expect(r['error'], contains(GlanceMiss.locked.label));
  });

  test('等到一半她打开了悬浮窗：不用再等，按悬浮窗截', () async {
    var n = 0;
    GlanceWindow.floating = () => ++n > 2;
    phone(checks: [
      {'miss': 'in_app'},
    ]);
    final r = await GlanceTool.execute({});

    expect(r['success'], isTrue);
    expect(argsOf('capture')['allowInApp'], isTrue);
  });
}
