import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/app_usage.dart';
import 'package:phone_ai_assistant/services/screen_glance.dart';

/// 看一眼屏幕的 Dart 这一侧。钉住的是**她那道开关**和**排除名单**：
/// 这两样在原生那边之前就得起作用，不能指望原生替我们记得。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('screen_glance');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void phone(Object? Function(MethodCall call) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('她没允许：不看，而且根本不去碰系统那边', () async {
    phone((_) => {'package': 'com.tencent.mm', 'label': '微信'});

    expect((await ScreenGlance.check()).miss, GlanceMiss.notAllowed);
    expect((await ScreenGlance.capture()).miss, GlanceMiss.notAllowed);
    expect(calls, isEmpty);
  });

  test('允许了：排除名单跟着每次调用一起过去', () async {
    await ScreenGlance.setAllowed(true);
    await AppUsage.setExcluded({'com.example.dating'});
    phone((_) => {'miss': 'excluded'});

    final r = await ScreenGlance.check();
    expect(r.miss, GlanceMiss.excluded);
    // 排除名单里的连名字都不该往回带。
    expect(r.appName, isNull);
    expect(calls.single.method, 'check');
    expect(
      (calls.single.arguments as Map)['excluded'],
      ['com.example.dating'],
    );
  });

  test('锁屏、灭屏、支付页：各自说得清为什么没看成', () async {
    await ScreenGlance.setAllowed(true);
    for (final (raw, want) in [
      ('locked', GlanceMiss.locked),
      ('screen_off', GlanceMiss.screenOff),
      ('in_app', GlanceMiss.inApp),
      ('secure', GlanceMiss.secure),
      ('off', GlanceMiss.off),
      ('something_new', GlanceMiss.failed),
    ]) {
      phone((_) => {'miss': raw});
      expect((await ScreenGlance.check()).miss, want, reason: raw);
    }
  });

  test('截到了：图、App 名字都在，缩图参数带过去', () async {
    await ScreenGlance.setAllowed(true);
    final webp = Uint8List.fromList([82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80]);
    phone(
      (_) => {'package': 'com.xingin.xhs', 'label': '小红书', 'bytes': webp},
    );

    final shot = await ScreenGlance.capture();
    expect(shot.ok, isTrue);
    expect(shot.bytes, webp);
    expect(shot.appName, '小红书');
    final args = calls.single.arguments as Map;
    expect(args['maxSide'], ScreenGlance.maxSide);
    expect(args['quality'], ScreenGlance.quality);
  });

  test('名字查不到就用包名', () async {
    await ScreenGlance.setAllowed(true);
    phone((_) => {'package': 'com.some.app'});
    expect((await ScreenGlance.check()).appName, 'com.some.app');
  });

  test('没有插件（不是安卓、测试环境）：当不支持，不抛', () async {
    await ScreenGlance.setAllowed(true);
    // 不装 mock handler = MissingPluginException。
    expect((await ScreenGlance.check()).miss, GlanceMiss.unsupported);
    final s = await ScreenGlance.status();
    expect(s.supported, isFalse);
    expect(s.ready, isFalse);
  });

  test('状态：开了但没绑上，不算能用', () async {
    phone((_) => {'supported': true, 'enabled': true, 'bound': false});
    final s = await ScreenGlance.status();
    expect(s.enabled, isTrue);
    expect(s.ready, isFalse);
  });

  test('上次看过的时间存得住', () async {
    final at = DateTime(2026, 9, 15, 16, 20);
    await ScreenGlance.markLooked(at);
    expect(await ScreenGlance.lastAt(), at);
  });
}
