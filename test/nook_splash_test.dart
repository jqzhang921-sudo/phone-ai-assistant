import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/widgets/nook_splash.dart';

void main() {
  group('splashTimeFor', () {
    test('5–15 点是早上', () {
      expect(splashTimeFor(5), SplashTime.morning);
      expect(splashTimeFor(12), SplashTime.morning);
      expect(splashTimeFor(14), SplashTime.morning);
    });
    test('15–19 点是傍晚', () {
      expect(splashTimeFor(15), SplashTime.evening);
      expect(splashTimeFor(18), SplashTime.evening);
    });
    test('其余是深夜', () {
      expect(splashTimeFor(19), SplashTime.night);
      expect(splashTimeFor(23), SplashTime.night);
      expect(splashTimeFor(0), SplashTime.night);
      expect(splashTimeFor(4), SplashTime.night);
    });
  });

  Widget host(VoidCallback onDone, DateTime now, {bool reduce = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(400, 860),
            disableAnimations: reduce,
          ),
          child: NookSplash(onDone: onDone, now: now),
        ),
      );

  for (final hour in [8, 17, 23]) {
    testWidgets('$hour 点：演完淡出，只叫一次 onDone', (tester) async {
      var done = 0;
      await tester.pumpWidget(host(() => done++, DateTime(2026, 9, 16, hour)));
      await tester.pump(const Duration(milliseconds: 900));
      expect(done, 0);
      await tester.pump(NookSplash.play);
      await tester.pump(NookSplash.fade + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(done, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('点一下就跳过', (tester) async {
    var done = 0;
    await tester.pumpWidget(host(() => done++, DateTime(2026, 9, 16, 23)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byType(NookSplash));
    await tester.pump();
    await tester.pump(NookSplash.fade + const Duration(milliseconds: 50));
    expect(done, 1);
  });

  testWidgets('系统减少动画：不演，稍停就淡出', (tester) async {
    var done = 0;
    await tester.pumpWidget(
      host(() => done++, DateTime(2026, 9, 16, 23), reduce: true),
    );
    await tester.pump(const Duration(milliseconds: 520));
    await tester.pump(NookSplash.fade + const Duration(milliseconds: 50));
    expect(done, 1);
  });
}
