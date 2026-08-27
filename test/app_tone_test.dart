import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/config/app_theme.dart';
import 'package:phone_ai_assistant/config/oklab.dart';

/// WCAG 对比度。信卡那条 bug 就是靠它量出来的（白字压强调色只有 1.8:1）。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 从背景图里取强调色的算法（`BackgroundProvider._analyze` 末尾）：
/// 只借色相，明度锁 OKLab 0.86、彩度 0.04–0.10。测试要用真的那一档，
/// 换个随手挑的颜色就测不到那个 bug。
Color _accent(double hue, double chroma) => fromOklch(0.86, chroma, hue);

void main() {
  group('AppTone.shift', () {
    // 这条是整个色相旋转的地基。转色相不管亮度的话，白字压 primary 的对比度
    // 会从 5.6:1 漂到 4.0:1——Cleo 调好的那套对比度会被悄悄冲掉，
    // 而且只在某几个背景下坏。钉住它。
    //
    // 容差 0.015：二分本身能到 1/262144，但要量化成 8 位色深，
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

    // 「同样的饱和度在不同色相上不是同一种花」那条。HSL 版本里
    // #D9B48F 转到绿会变成 #9AC85E（刺眼的草绿），OKLCH 版本不会。
    test('转完色相，彩度不变——不会转到绿就突然变艳', () {
      final before = toOklch(const Color(0xFFD9B48F)).c;
      for (final hue in <double>[0, 60, 120, 180, 240, 300]) {
        final after = toOklch(AppTone(hueDelta: hue).shift(
          const Color(0xFFD9B48F),
        )).c;
        expect(after, closeTo(before, 0.012), reason: 'hueDelta=$hue');
      }
    });

    test('alpha 原样带过去', () {
      final tone = AppTone(hueDelta: 120);
      expect(tone.shift(const Color(0x99E2DACE)).a, closeTo(0x99 / 255, 0.004));
    });

    test('色相真的转到目标上了', () {
      final pink = _accent(330, 0.07);
      final tone = AppTone.towards(pink);
      final shifted = tone.shift(AppTheme.brandBrown);
      expect(toOklch(shifted).h, closeTo(toOklch(pink).h, 2));
    });

    test('none 不动任何颜色', () {
      expect(AppTone.none.shift(AppTheme.brandBrown), AppTheme.brandBrown);
      expect(AppTone.none.isIdentity, isTrue);
    });

    test('neutral 只降彩度，色相和亮度都不动', () {
      const brown = AppTheme.brandBrown;
      final out = AppTone.neutral.shift(brown);
      expect(toOklch(out).c, closeTo(toOklch(brown).c * 0.35, 0.01));
      expect(toOklch(out).h, closeTo(toOklch(brown).h, 2));
      expect(out.computeLuminance(), closeTo(brown.computeLuminance(), 0.015));
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
        for (final chroma in <double>[0.04, 0.07, 0.10]) {
          final fill = _accent(hue, chroma);
          final fg = AppTone.none.inkOn(fill);
          expect(
            _contrast(fill, fg),
            greaterThan(4.5),
            reason: 'accent hue=$hue chroma=$chroma 上的前景色读不清',
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
