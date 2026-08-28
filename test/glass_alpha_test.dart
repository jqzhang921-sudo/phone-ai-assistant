import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/widgets/glass_surface.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _over(Color base, Color under, double alpha) => Color.from(
  alpha: 1,
  red: base.r * alpha + under.r * (1 - alpha),
  green: base.g * alpha + under.g * (1 - alpha),
  blue: base.b * alpha + under.b * (1 - alpha),
);

/// 卡片里的字走 scheme.onSurface：亮底玻璃配深字、暗底玻璃配浅字。
const _textOnLight = Color(0xFF1A1512);
const _textOnDark = Color(0xFFF2EAE0);

void main() {
  test('压在图最极端的地方也读得清', () {
    for (final extreme in <double>[0, 0.2, 0.5, 0.72, 0.9, 1]) {
      for (final busyness in <double>[0, 0.22, 0.6, 1]) {
        for (final lightGlass in <bool>[true, false]) {
          final a = glassAlpha(
            busyness: busyness,
            floating: false,
            extreme: extreme,
            lightGlass: lightGlass,
          );
          final base = lightGlass ? glassBaseLight : glassBaseDark;
          final text = lightGlass ? _textOnLight : _textOnDark;
          // 极端处按同亮度的灰算
          var lo = 0.0, hi = 1.0;
          for (var i = 0; i < 20; i++) {
            final m = (lo + hi) / 2;
            if (Color.from(
                  alpha: 1,
                  red: m,
                  green: m,
                  blue: m,
                ).computeLuminance() <
                extreme) {
              lo = m;
            } else {
              hi = m;
            }
          }
          final g = (lo + hi) / 2;
          final under = Color.from(alpha: 1, red: g, green: g, blue: g);
          expect(
            _contrast(_over(base, under, a), text),
            greaterThan(4.4),
            reason:
                'extreme=$extreme busyness=$busyness lightGlass=$lightGlass '
                'alpha=$a',
          );
        }
      }
    }
  });

  // 这条是那张黑底骷髅壁纸的回归测试。它的 busyness 只有 0.22——按「花不花」
  // 算 alpha 只到 0.39，骷髅的高光从书卡里透出来，实测书名只剩 1.9:1。
  // 亮端 p95 量出来在 0.7 上下。
  test('黑底 + 一小块高光：busyness 低，但 alpha 必须高', () {
    final byLook = glassAlpha(
      busyness: 0.22,
      floating: false,
      extreme: 0, // 假装图上没有亮处
      lightGlass: false,
    );
    final real = glassAlpha(
      busyness: 0.22,
      floating: false,
      extreme: 0.72, // 真实亮端
      lightGlass: false,
    );
    // 现在观感那条线本身就在 0.62 以上了，可读性那条只在更极端时才顶上来。
    // 留着这条是为了记住：两条线量的是不同的东西，别再把 busyness 当可读性用。
    expect(real, greaterThanOrEqualTo(byLook));
  });

  // 设计交付给的档：浅 0.55–0.65 / 暗 0.62–0.70。平滑的图落在档底，
  // 花的图落在档顶；再花或再极端就由可读性那条线接管。
  test('观感那条线落在设计交付给的档位里', () {
    expect(
      glassAlpha(busyness: 0, floating: false, extreme: 0.6, lightGlass: true),
      closeTo(0.55, 0.005),
    );
    expect(
      glassAlpha(busyness: 1, floating: false, extreme: 0.6, lightGlass: true),
      closeTo(0.65, 0.005),
    );
    expect(
      glassAlpha(busyness: 0, floating: false, extreme: 0.1, lightGlass: false),
      closeTo(0.62, 0.005),
    );
    expect(
      glassAlpha(busyness: 1, floating: false, extreme: 0.1, lightGlass: false),
      closeTo(0.70, 0.005),
    );
  });

  test('悬浮那档更厚，且不越界', () {
    final card = glassAlpha(
      busyness: 0.5,
      floating: false,
      extreme: 0.5,
      lightGlass: false,
    );
    final floating = glassAlpha(
      busyness: 0.5,
      floating: true,
      extreme: 0.5,
      lightGlass: false,
    );
    expect(floating, greaterThan(card));
    expect(
      glassAlpha(
        busyness: 1,
        floating: true,
        extreme: 1,
        lightGlass: false,
      ),
      lessThanOrEqualTo(1),
    );
  });
}
