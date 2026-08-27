import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 毛玻璃表面。玻璃主题下卡片、导航条、标题栏都走它。
///
/// ## 什么时候它是有意义的
///
/// 毛玻璃糊的是**底下的东西**。底下要是一整块纯色（App 默认的
/// `scheme.surface`），糊完还是同一个颜色——白付一次 `saveLayer` 加一次全屏
/// 高斯模糊，换来零效果。所以调用方必须先确认真的贴了背景图，
/// 没有就别用这个组件，用普通 Container。
///
/// ## 为什么 alpha 是算出来的，不是写死的
///
/// 可读性取决于用户挑了什么图，而那是控制不了的。Cleo 的七张壁纸里，
/// 五张是几乎没有细节的柔和渐变（很通透也读得清），一张是带雨丝和伞骨的暗图
/// （同样参数下正文就开始费劲）。
///
/// 所以 alpha 跟着 [busyness] 走：渐变底给到最通透，花的图自动加厚。
/// busyness 由 `BackgroundProvider` 在解析背景图时一并算出（亮度标准差）。
///
/// ## saturate 那一下是关键
///
/// 只降 alpha 会让卡片发灰——背景透上来的颜色被卡片本身的白/黑冲淡了，
/// 看起来是「变透明」而不是「晕染」。Flutter 没有 CSS 那种 `saturate()`，
/// 这里用一层极淡的、取自背景强调色的叠色把彩度补回来。
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;

  /// 0 = 纯色渐变底，1 = 到处都是细节。见 `BackgroundProvider.backgroundBusyness`。
  final double busyness;

  /// 底下的背景偏亮时传 true——决定玻璃是白的还是黑的。
  final bool lightBackground;

  /// 背景图给出的强调色，用来把透过来的彩度补回去。null 就不补。
  final Color? tint;

  /// 导航条这类浮在内容之上的表面传 true：它糊的是正在滚动的真实内容，
  /// 值得比卡片再厚一点、模糊再大一点，免得滚动时底下的字糊成一团噪点。
  final bool floating;

  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.busyness,
    required this.lightBackground,
    this.tint,
    this.floating = false,
  });

  /// 三档实验值里选的中间那档（alpha .34 / blur 44），再按 busyness 上浮。
  /// 渐变底（busyness≈0）落在 .30，最花的图落在 .52——那正是「稳但像贴纸」
  /// 那一档，此时本来也该稳优先。
  double get _alpha {
    final base = 0.30 + busyness * 0.22;
    return floating ? (base + 0.06).clamp(0.0, 0.62) : base;
  }

  double get _blur => floating ? 46 : 44;

  @override
  Widget build(BuildContext context) {
    final base = lightBackground ? const Color(0xFFFFFDFB) : const Color(0xFF1A1410);
    final line =
        lightBackground
            ? Colors.white.withValues(alpha: 0.52)
            : const Color(0xFFF2EAE0).withValues(alpha: 0.14);

    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: _blur, sigmaY: _blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: _alpha),
            borderRadius: borderRadius,
            border: Border.all(color: line, width: 1),
          ),
          child:
              tint == null
                  ? child
                  // 补彩度：极淡的一层背景色叠上去，让透过来的粉/蓝是活的。
                  // 0.05 是上限——再高就从「晕染」变成「染色」，卡片会显脏。
                  : DecoratedBox(
                    decoration: BoxDecoration(
                      color: tint!.withValues(alpha: 0.05),
                      borderRadius: borderRadius,
                    ),
                    child: child,
                  ),
        ),
      ),
    );
  }
}
