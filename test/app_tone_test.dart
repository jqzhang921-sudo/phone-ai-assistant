import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/config/app_theme.dart';

/// WCAG 对比度。信卡那条 bug 就是靠它量出来的（白字压强调色只有 1.8:1）。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 从背景图里取强调色的算法（`BackgroundProvider._analyze` 末尾）：
/// 只借色相，明度锁死 V=0.85、饱和度 0.14–0.35。测试要用真的那一档，
/// 换个随手挑的颜色就测不到那个 bug。
Color _accent(double hue, double sat) =>
    HSVColor.fromAHSV(1, hue, sat, 0.85).toColor();

void main() {
  group('AppTone.shift', () {
    // 这条是整个色相旋转的地基。只换色相、L 原样留着的话，`#8B5E34` 转到
    // 黄绿会让白字上的对比度从 5.6:1 掉到 4.0:1——Cleo 调好的那套对比度
    // 会被悄悄冲掉，而且只在某几个背景下坏。钉住它。
    //
    // 容差 0.015：二分本身能到 1/262144，但 toColor() 要量化成 8 位，
    // 最亮那几档一个 LSB 就值约 0.006。
    test('转完色相，相对亮度不变', () {
      const palette = <Color>[
        AppTheme.brandBrown, // primary
        Color(0xFFD9B48F), // secondary
        Color(0xFF787168), // 唯一那档次级灰
        Color(0xFFFDF8F1), // 奶白底
        Color(0xFF171310), // 暖黑底
        Color(0x99E2DACE), // 用户气泡（带 alpha）
        Color(0xFF1A1410), // 玻璃本体（深）
      ];
      for (final hue in <double>[0, 90, 180, 210, 330]) {
        final tone = AppTone(hueDelta: hue);
        for (final c in palette) {
          expect(
            tone.shift(c).computeLuminance(),
            closeTo(c.computeLuminance(), 0.015),
            reason: 'hueDelta=$hue color=$c',
          );
        }
      }
    });

    test('alpha 原样带过去', () {
      final tone = AppTone(hueDelta: 120);
      expect(tone.shift(const Color(0x99E2DACE)).a, closeTo(0x99 / 255, 0.004));
    });

    test('色相真的转到目标上了', () {
      final pink = _accent(330, 0.25);
      final tone = AppTone.towards(pink);
      final shifted = tone.shift(AppTheme.brandBrown);
      expect(HSLColor.fromColor(shifted).hue, closeTo(330, 2));
    });

    test('none 不动任何颜色', () {
      expect(AppTone.none.shift(AppTheme.brandBrown), AppTheme.brandBrown);
      expect(AppTone.none.isIdentity, isTrue);
    });

    test('neutral 只降彩度，色相和亮度都不动', () {
      final out = AppTone.neutral.shift(AppTheme.brandBrown);
      final before = HSLColor.fromColor(AppTheme.brandBrown);
      final after = HSLColor.fromColor(out);
      expect(after.saturation, closeTo(before.saturation * 0.35, 0.02));
      expect(after.hue, closeTo(before.hue, 2));
      expect(out.computeLuminance(), closeTo(0.1365, 0.015));
    });

    test('纯白纯黑不受影响（转色相是恒等变换）', () {
      final tone = AppTone(hueDelta: 200);
      expect(tone.shift(Colors.white), Colors.white);
      expect(tone.shift(Colors.black), Colors.black);
    });
  });

  group('AppTone.inkOn', () {
    // 栖息页那张信卡的回归测试。原来前景写死 `scheme.onPrimary`（白），
    // 而底色是运行时算出来的强调色——白字压上去 1.6–2.6:1，基本看不见。
    test('强调色那一档底色上，前景必须过 4.5:1', () {
      for (final hue in <double>[0, 30, 90, 200, 330]) {
        for (final sat in <double>[0.14, 0.25, 0.35]) {
          final fill = _accent(hue, sat);
          final fg = AppTone.none.inkOn(fill);
          expect(
            _contrast(fill, fg),
            greaterThan(4.5),
            reason: 'accent hue=$hue sat=$sat 上的前景色读不清',
          );
          // 顺带钉住 bug 本身：这一档底色上白字就是不够
          expect(_contrast(fill, Colors.white), lessThan(3));
        }
      }
    });

    test('深底上回白字', () {
      expect(AppTone.none.inkOn(AppTheme.brandBrown), Colors.white);
    });
  });

  group('主题', () {
    test('报错色不跟着转色相——红色必须是红色', () {
      final brown = AppTheme.lightWith(titleSerif: false).colorScheme;
      final rotated =
          AppTheme.lightWith(
            titleSerif: false,
            tone: AppTone(hueDelta: 200),
          ).colorScheme;
      expect(rotated.error, brown.error);
      expect(rotated.onError, brown.onError);
      expect(rotated.errorContainer, brown.errorContainer);
      // 对照：主色确实转了，不然上面那条是废的
      expect(rotated.primary, isNot(brown.primary));
    });

    test('tone 挂进了主题扩展，widget 取得到', () {
      final tone = AppTone(hueDelta: 120);
      final theme = AppTheme.darkWith(titleSerif: true, tone: tone);
      expect(theme.extension<AppTone>(), tone);
    });

    test('不传 tone 时和原来那套棕一模一样', () {
      final a = AppTheme.lightWith(titleSerif: false).colorScheme;
      expect(a.primary, AppTheme.brandBrown);
      expect(a.surface, AppTheme.surfaceLight);
    });
  });
}
