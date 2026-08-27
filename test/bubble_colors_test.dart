import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/config/app_theme.dart';
import 'package:phone_ai_assistant/widgets/message_bubble.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 把半透明的气泡底色合成到一个已知底上。贴了背景图之后，底下是一张照片，
/// 最亮和最暗的地方就是纯白和纯黑——两头都过了才叫「不依赖底下是什么」。
Color _over(Color fill, Color under) => Color.from(
  alpha: 1,
  red: fill.r * fill.a + under.r * (1 - fill.a),
  green: fill.g * fill.a + under.g * (1 - fill.a),
  blue: fill.b * fill.a + under.b * (1 - fill.a),
);

void main() {
  // 这一条是「用户气泡在兔子那块亮的地方整句话消失」的回归测试。
  // 深色模式下用户气泡原本是 15% 的浅棕，指望底下是一整块 #171310；
  // 换成照片就不成立了。
  test('贴了背景图时，气泡压在纯白和纯黑上都读得清', () {
    final tones = <AppTone>[
      AppTone.none,
      AppTone.neutral,
      AppTone.towards(const Color(0xFFDFADC4)),
    ];
    for (final tone in tones) {
      for (final dark in <bool>[true, false]) {
        final scheme =
            (dark
                    ? AppTheme.darkWith(titleSerif: false, tone: tone)
                    : AppTheme.lightWith(titleSerif: false, tone: tone))
                .colorScheme;
        for (final lightSurface in <bool>[true, false]) {
          for (final busyness in <double>[0, 0.5, 1]) {
            for (final isUser in <bool>[true, false]) {
              final c = bubbleColors(
                isUser: isUser,
                dark: dark,
                onPhoto: true,
                lightSurface: lightSurface,
                busyness: busyness,
                tone: tone,
                scheme: scheme,
              );
              for (final under in <Color>[Colors.white, Colors.black]) {
                expect(
                  _contrast(_over(c.fill, under), c.text),
                  greaterThan(4.5),
                  reason:
                      'dark=$dark lightSurface=$lightSurface '
                      'busyness=$busyness isUser=$isUser under=$under',
                );
              }
            }
          }
        }
      }
    }
  });

  test('没有背景图时保持原样——那套是照着页面底色调的，别动', () {
    final scheme = AppTheme.lightWith(titleSerif: false).colorScheme;
    final user = bubbleColors(
      isUser: true,
      dark: false,
      onPhoto: false,
      lightSurface: true,
      busyness: 0,
      tone: AppTone.none,
      scheme: scheme,
    );
    expect(user.fill, const Color(0x99E2DACE));
    expect(user.text, const Color(0xFF4A3320));
  });

  test('两侧分得开', () {
    final scheme = AppTheme.lightWith(titleSerif: false).colorScheme;
    ({Color fill, Color text}) at(bool isUser) => bubbleColors(
      isUser: isUser,
      dark: true,
      onPhoto: true,
      lightSurface: false,
      busyness: 0.4,
      tone: AppTone.none,
      scheme: scheme,
    );
    expect(at(true).fill, isNot(at(false).fill));
  });
}
