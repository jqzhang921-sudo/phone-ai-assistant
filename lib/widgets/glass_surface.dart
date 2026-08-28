import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/app_shape.dart';
import '../config/app_theme.dart';

/// 玻璃本体的两套基色：暖白 / 暖黑。跟着 tone 转（见 [GlassSurface.build]）。
const Color glassBaseLight = Color(0xFFFFFDFB);
const Color glassBaseDark = Color(0xFF1A1410);

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
/// 具体的档位和它为什么是这个档位，见 [glassAlpha]。
///
/// ## saturate 那一下是关键
///
/// 只降 alpha 会让卡片发灰——背景透上来的颜色被卡片本身的白/黑冲淡了，
/// 看起来是「变透明」而不是「晕染」。Flutter 没有 CSS 那种 `saturate()`，
/// 这里用一层极淡的、取自背景强调色的叠色把彩度补回来。
/// 卡片里的字色：亮底玻璃配深字、暗底玻璃配浅字（就是 `scheme.onSurface`
/// 那两档）。色相旋转不动相对亮度，所以这两个值在任何色调下都成立。
const _textOnLightGlass = Color(0xFF1A1512);
const _textOnDarkGlass = Color(0xFFF2EAE0);

/// 玻璃要多不透明。两条线取大的那条。
///
/// **一、观感**：浅底 0.55–0.65 / 暗底 0.62–0.70，按 busyness 在档内浮动。
/// 档位来自设计交付（`落地清单.md` 追加清单 §3）；暗底更实，因为糊过的背景
/// 在暗底上更容易显脏。
///
/// 这一档比之前高很多（原来是 `0.30 + busyness * 0.40`，平滑底只有 0.30）。
/// **它和模糊半径是一对**：原来靠 sigma 44 的大模糊把背景抹匀来撑可读性，
/// 代价是背景糊成一片灰、卡片看着「脏」而不是「透」。现在反过来——
/// 卡片自己更实，模糊收到 16，背景透出来的是**看得出是什么**的东西。
///
/// **二、读得清**：压在这张图最极端的地方（[extreme]，亮玻璃看暗端、
/// 暗玻璃看亮端）合成之后仍要过 4.5:1。二分求出这个最小 alpha。
///
/// ⚠️ 第二条不能拿 busyness 代替，实测栽过两次：
///
/// - 一开始系数是 0.22，最花的图也只到 0.52，而深色玻璃压在纯白上要 0.634。
/// - 提到 0.40 之后还是不够——Cleo 那张黑底骷髅壁纸的 busyness 只有 0.22
///   （缩略图上绝大多数像素是黑的，标准差自然小），alpha 只到 0.39，
///   骷髅的高光从书卡里透出来，量出来书名只有 1.9:1。
///
/// **「花不花」和「能有多亮」是两件事。** 一小块高光推不高标准差，却足以让
/// 一整行字看不见。观感归 busyness 管，可读性归 extreme 管，谁也替不了谁。
///
/// 悬浮那档（导航条）再厚 0.06：它糊的是正在滚动的真实内容，不是静止的壁纸。
double glassAlpha({
  required double busyness,
  required bool floating,
  required double extreme,
  required bool lightGlass,
}) {
  final look =
      lightGlass ? 0.55 + busyness * 0.10 : 0.62 + busyness * 0.08;
  final base = lightGlass ? glassBaseLight : glassBaseDark;
  final text = lightGlass ? _textOnLightGlass : _textOnDarkGlass;
  // 把最极端处当成一块同亮度的灰来合成。真实像素当然有色相，但对比度只看
  // 亮度，用灰做代理算出来的门槛和真值差不了多少，还省掉一次全图采样。
  final under = _grayOf(extreme);

  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 14; i++) {
    final mid = (lo + hi) / 2;
    if (_contrast(_composite(base, under, mid), text) < 4.5) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final readable = hi;

  final alpha = look > readable ? look : readable;
  return (floating ? alpha + 0.06 : alpha).clamp(0.0, 0.92);
}

Color _grayOf(double luminance) {
  // 二分出相对亮度等于 luminance 的那一档灰
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 14; i++) {
    final mid = (lo + hi) / 2;
    if (Color.from(alpha: 1, red: mid, green: mid, blue: mid)
            .computeLuminance() <
        luminance) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final v = (lo + hi) / 2;
  return Color.from(alpha: 1, red: v, green: v, blue: v);
}

Color _composite(Color base, Color under, double alpha) => Color.from(
  alpha: 1,
  red: base.r * alpha + under.r * (1 - alpha),
  green: base.g * alpha + under.g * (1 - alpha),
  blue: base.b * alpha + under.b * (1 - alpha),
);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

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

  /// 背景图的亮端 / 暗端（相对亮度）。见 `BackgroundProvider.backgroundPeak`。
  final double peak;
  final double trough;

  const GlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.busyness,
    required this.lightBackground,
    required this.peak,
    required this.trough,
    this.tint,
    this.floating = false,
  });

  double get _alpha => glassAlpha(
    busyness: busyness,
    floating: floating,
    // 亮玻璃怕的是图上最暗的地方，暗玻璃怕的是最亮的地方。
    extreme: lightBackground ? trough : peak,
    lightGlass: lightBackground,
  );

  /// 设计交付给的档是 12–16：「超过 ~20 背景全糊成灰，卡片看着『脏』
  /// 不是『透』」。原来是 44——那是 alpha 只有 0.30 时用大模糊兼职撑可读性，
  /// 现在 alpha 抬上去了，模糊就该退回它自己的活儿。
  ///
  /// 悬浮那档略大：它糊的是**正在滚动的真实内容**，糊得不够会看见字在底下爬。
  double get _blur => floating ? 20 : 16;

  @override
  Widget build(BuildContext context) {
    // 玻璃本身也是暖色的（暖白 / 暖黑），跟着 tone 转——不然卡片透出粉色，
    // 玻璃那层却还带着棕味，透出来的颜色会发脏。
    final tone = AppTone.of(context);
    final base = tone.shift(lightBackground ? glassBaseLight : glassBaseDark);

    // 卡片的边缘怎么立起来，浅底和暗底是两套办法——就是主题里那两条老规矩：
    // **浅色靠阴影不靠描边**（描边是「碎线太多」的主因），
    // **深色不画阴影**（暗底上的黑影看不见），改用一道亮边。
    //
    // 原来两边都画描边，而且浅底画的是 **52% 的纯白**：白卡压在亮壁纸上，
    // 白描边等于没画，卡片整个糊进背景里。Cleo 的原话是「刚才的黑色主题，
    // 卡片就很好看，边缘亮亮的，能看出来是卡片，现在这个就有点模糊了」
    // ——她夸的正是暗底那道亮边，缺的是浅底这一侧的对应物。
    final glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: _blur, sigmaY: _blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: _alpha),
            borderRadius: borderRadius,
            border:
                lightBackground
                    ? null
                    : Border.all(
                      color: tone
                          .shift(const Color(0xFFF2EAE0))
                          .withValues(alpha: 0.14),
                      width: 1,
                    ),
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

    if (!lightBackground) return glass;

    // 阴影必须画在 ClipRRect **外面**，不然被裁掉。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow:
            floating ? AppShadow.softenFloating(false) : AppShadow.soften(false),
      ),
      child: glass,
    );
  }
}
