import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/config/oklab.dart';

void main() {
  group('接近黑的像素', () {
    // 整个「黑底粉兔子壁纸变成蓝紫主题」的根。HSV 的 s = (max-min)/max
    // 在 max→0 时剧烈抖动，于是黑底噪点拿到了和真彩色一样大的发言权。
    // OKLab 彩度不会——这条钉住的就是这个差别。
    test('HSV 说它很饱和，OKLab 说它几乎没有颜色', () {
      const nearBlack = Color.fromARGB(255, 10, 8, 12);

      final hsv = HSVColor.fromColor(nearBlack);
      expect(hsv.saturation, greaterThan(0.3)); // ← 噪声被放大成「很有颜色」

      expect(toOklch(nearBlack).c, lessThan(0.02)); // ← 实际上几乎没有颜色
    });

    // 只看彩度还不够。近黑像素的彩度虽然比 HSV 老实得多，但一整片系统性
    // 偏冷的黑仍然能攒够票（实测合成图只用彩度得 321°，黑更深更冷时漂到
    // 307°）。乘上明度才把它压下去——这条钉住那个乘法。
    test('一个近黑像素的发言权远小于一个粉像素', () {
      const nearBlack = Color.fromARGB(255, 8, 6, 14);
      const pink = Color(0xFFF0C8DC);

      // 光看彩度只差三倍出头，压不住数量差
      expect(toOklch(pink).c / toOklch(nearBlack).c, lessThan(6));

      // 算上明度是十八倍，数量再多也翻不了盘
      expect(hueWeight(pink) / hueWeight(nearBlack), greaterThan(15));
    });

    test('纯灰的发言权是 0', () {
      for (final v in <int>[0, 64, 128, 200, 255]) {
        expect(hueWeight(Color.fromARGB(255, v, v, v)), lessThan(0.001));
      }
    });
  });

  group('转换', () {
    test('来回转一圈还是原来的颜色', () {
      const palette = <Color>[
        Color(0xFF8B5E34),
        Color(0xFFD9B48F),
        Color(0xFF787168),
        Color(0xFFFDF8F1),
        Color(0xFF171310),
        Color(0xFF1A1410),
        Color(0xFFBA1A1A),
      ];
      for (final c in palette) {
        final lch = toOklch(c);
        final back = fromOklch(lch.l, lch.c, lch.h);
        expect((back.r - c.r).abs(), lessThan(0.004), reason: '$c');
        expect((back.g - c.g).abs(), lessThan(0.004), reason: '$c');
        expect((back.b - c.b).abs(), lessThan(0.004), reason: '$c');
      }
    });

    test('纯灰的彩度是 0', () {
      for (final v in <int>[0, 64, 128, 200, 255]) {
        expect(toOklch(Color.fromARGB(255, v, v, v)).c, lessThan(0.001));
      }
    });

    test('同样的彩度，各色相之间是可比的', () {
      // HSL 做不到这件事：同样 0.49 的饱和度，棕色是柔的、绿色是刺眼的。
      // OKLCH 里同一个 c 出来的「花」的程度一致——这就是不再用 HSL 的理由。
      const chroma = 0.08;
      for (final h in <double>[30, 90, 150, 210, 270, 330]) {
        expect(toOklch(fromOklch(0.6, chroma, h)).c, closeTo(chroma, 0.005));
      }
    });
  });
}
