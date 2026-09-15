import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/glance_health.dart';
import 'package:phone_ai_assistant/services/screen_glance.dart';

/// 「看一眼屏幕」断了要告诉她，但别吵。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('screen_glance');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final defaultShow = GlanceHealth.show;
  late List<String> shown;

  void system({required bool enabled, required bool bound}) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return {'supported': true, 'enabled': enabled, 'bound': bound};
      }
      return null;
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    shown = [];
    GlanceHealth.show = (title, body) async => shown.add(title);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    GlanceHealth.show = defaultShow;
  });

  group('什么算断了', () {
    test('允许了、系统里开着、但没绑上：断了', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: false);
      expect(await GlanceHealth.broken(), isTrue);
    });

    test('好好绑着：没断', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: true);
      expect(await GlanceHealth.broken(), isFalse);
    });

    test('系统里本来就没开：那是她的选择，不算故障', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: false, bound: false);
      expect(await GlanceHealth.broken(), isFalse);
    });

    test('App 里没允许：不管系统那边怎样都不提醒', () async {
      system(enabled: true, bound: false);
      expect(await GlanceHealth.broken(), isFalse);
    });
  });

  group('后台提醒', () {
    final t0 = DateTime(2026, 9, 15, 23, 30);

    test('断了就提醒一次；12 小时内再醒来不重复', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: false);

      expect(await GlanceHealth.notifyIfBroken(now: t0), isTrue);
      expect(
        await GlanceHealth.notifyIfBroken(now: t0.add(const Duration(hours: 3))),
        isFalse,
      );
      expect(shown, hasLength(1));
    });

    test('过了 12 小时还断着：再提醒', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: false);

      await GlanceHealth.notifyIfBroken(now: t0);
      expect(
        await GlanceHealth.notifyIfBroken(now: t0.add(const Duration(hours: 13))),
        isTrue,
      );
      expect(shown, hasLength(2));
    });

    test('好好的时候不提醒，也不记时间——之后真断了能马上说', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: true);
      expect(await GlanceHealth.notifyIfBroken(now: t0), isFalse);

      system(enabled: true, bound: false);
      expect(
        await GlanceHealth.notifyIfBroken(now: t0.add(const Duration(minutes: 15))),
        isTrue,
      );
      expect(shown, hasLength(1));
    });

    test('发通知出错：不抛，这一轮主动说话照常', () async {
      await ScreenGlance.setAllowed(true);
      system(enabled: true, bound: false);
      GlanceHealth.show = (_, __) async => throw Exception('没有通知插件');
      expect(await GlanceHealth.notifyIfBroken(now: t0), isFalse);
    });
  });
}
