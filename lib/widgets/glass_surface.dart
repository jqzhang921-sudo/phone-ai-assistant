import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config/app_shape.dart';
import '../config/app_theme.dart';

/// 折射用的着色器，全 App 共用一份。
///
/// ## 为什么要有它
///
/// 模糊 + 提饱和度已经让玻璃「透」了，但还是**平的**——像一层贴纸，不像一块
/// 有厚度的东西。真玻璃的厚度是在**边缘**看出来的：光穿过边缘会被弯折，
/// 所以透过边看到的背景是被推开的。Cleo 看别人 App 时的原话是
/// 「像拿了凸透镜或凹透镜那样，很自然的光线」。
///
/// ## 三个前提，缺一不可
///
/// 1. **Impeller 必须开着**——`ImageFilter.shader` 在 Skia 下直接抛
///    UnsupportedError。这个仓库为了修 OPPO 的文字渲染，2026-09-08 之前
///    一直关着它。
/// 2. 着色器是异步加载的，第一帧拿不到——所以下面用 null 表示「还没好」，
///    这时候照常走「模糊 + 饱和度」，不闪不崩。
/// 3. 加载失败（老设备、驱动不支持）也走同一条回落路径。
///
/// **玻璃在没有折射的情况下必须仍然是好看的**，折射是锦上添花，不是地基。
class _RefractProgram {
  /// null = 还没加载好 / 不支持。用 ValueNotifier 是因为着色器是**异步**来的：
  /// 第一帧玻璃已经画出来了，等它到了得让那些卡片重画一次，
  /// 否则要等到下次滚动才生效。
  static final ValueNotifier<ui.FragmentProgram?> notifier = ValueNotifier(
    null,
  );
  static bool _tried = false;

  static void ensureLoaded() {
    if (_tried) return;
    _tried = true;
    _load();
  }

  static Future<void> _load() async {
    if (!ui.ImageFilter.isShaderFilterSupported) {
      debugPrint('[glass] 后端不支持 shader 滤镜，折射关闭（Impeller 没开？）');
      return;
    }
    try {
      notifier.value = await ui.FragmentProgram.fromAsset(
        'shaders/glass_refract.frag',
      );
    } catch (e) {
      debugPrint('[glass] 折射着色器加载失败，回落到纯模糊：$e');
    }
  }
}

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
  final look = lightGlass ? 0.55 + busyness * 0.10 : 0.62 + busyness * 0.08;
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
    if (Color.from(
          alpha: 1,
          red: mid,
          green: mid,
          blue: mid,
        ).computeLuminance() <
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

class GlassSurface extends StatefulWidget {
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

  @override
  State<GlassSurface> createState() => _GlassSurfaceState();
}

class _GlassSurfaceState extends State<GlassSurface> {
  /// 每张卡片自己一份 shader 实例：uniform 是写在实例上的，
  /// 共用一份会让相邻卡片互相覆盖对方的圆角和厚度。
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _RefractProgram.ensureLoaded();
    _RefractProgram.notifier.addListener(_onProgram);
    _onProgram();
  }

  void _onProgram() {
    final p = _RefractProgram.notifier.value;
    if (p == null || _shader != null || !mounted) return;
    setState(() => _shader = p.fragmentShader());
  }

  @override
  void dispose() {
    _RefractProgram.notifier.removeListener(_onProgram);
    _shader?.dispose();
    super.dispose();
  }

  double get _alpha => glassAlpha(
    busyness: widget.busyness,
    floating: widget.floating,
    // 亮玻璃怕的是图上最暗的地方，暗玻璃怕的是最亮的地方。
    extreme: widget.lightBackground ? widget.trough : widget.peak,
    lightGlass: widget.lightBackground,
  );

  /// 设计交付给的档是 12–16：「超过 ~20 背景全糊成灰，卡片看着『脏』
  /// 不是『透』」。原来是 44——那是 alpha 只有 0.30 时用大模糊兼职撑可读性，
  /// 现在 alpha 抬上去了，模糊就该退回它自己的活儿。
  ///
  /// 悬浮那档略大：它糊的是**正在滚动的真实内容**，糊得不够会看见字在底下爬。
  double get _blur => widget.floating ? 20 : 16;

  /// 模糊 → 提饱和度 → 边缘折射，三层套在一起。
  ///
  /// `compose(outer: A, inner: B)` 是**先 B 后 A**，所以折射在最外层：
  /// 它扭的是已经糊过、提过彩度的那张图，而不是原始背景。
  ///
  /// 着色器没加载好（或者 Impeller 没开）就只有前两层——**玻璃在没有折射的
  /// 情况下必须仍然是好看的**，折射是锦上添花，不是地基。
  ui.ImageFilter _filter(double dpr) {
    final base = ui.ImageFilter.compose(
      outer: _saturate(1.8),
      // ⚠️ 别再试 tileMode 了。
      //
      // 2026-09-09 试过 `TileMode.mirror`（社区里治「安卓滚动时玻璃闪一下」
      // 的说法之一），真机上**看不出任何区别**，改回默认。
      //
      // 原因想明白了：mirror 治的是模糊采样到区域**外面**时怎么补边，
      // 而那个闪的成因是**滚动时列表被提成独立图层、采样跟不上位移**——
      // 两回事。根治要靠「预先糊好壁纸 + 按卡片位置裁剪」，
      // 静止的壁纸本来就不需要每帧实时采样。
      inner: ui.ImageFilter.blur(sigmaX: _blur, sigmaY: _blur),
    );
    final sh = _shader;
    if (sh == null) return base;

    // ⚠️ uniform 的下标要跟着色器里的声明顺序数。
    // 前两个 float 是 uSize（vec2），**由引擎自动填**，不能自己写。
    // 所以 uRadius 是 2，uThickness 是 3，uStrength 是 4。
    //
    // 着色器里的坐标是纹理像素，而 Flutter 这边的圆角是逻辑像素，
    // 所以统统乘 dpr——不乘的话在 3x 屏上折射带只有实际的三分之一宽。
    final r = widget.borderRadius.topLeft.x;
    sh.setFloat(2, r * dpr);
    sh.setFloat(3, _refractBand * dpr);
    sh.setFloat(4, _refractPush * dpr);
    return ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(sh),
      inner: base,
    );
  }

  /// 折射带有多宽（逻辑像素）。只有这一圈里的背景会被推开，中间原样透过。
  /// 太宽会让整张卡看着糊，太窄看不出厚度。
  double get _refractBand => widget.floating ? 14 : 10;

  /// 边上把背景往外推多少（逻辑像素）。这个数决定「透镜感」有多强。
  double get _refractPush => widget.floating ? 8 : 6;

  @override
  Widget build(BuildContext context) {
    // 玻璃本身也是暖色的（暖白 / 暖黑），跟着 tone 转——不然卡片透出粉色，
    // 玻璃那层却还带着棕味，透出来的颜色会发脏。
    final tone = AppTone.of(context);
    final base = tone.shift(
      widget.lightBackground ? glassBaseLight : glassBaseDark,
    );

    // 卡片的边缘怎么立起来，浅底和暗底是两套办法——就是主题里那两条老规矩：
    // **浅色靠阴影不靠描边**（描边是「碎线太多」的主因），
    // **深色不画阴影**（暗底上的黑影看不见），改用一道亮边。
    //
    // 原来两边都画描边，而且浅底画的是 **52% 的纯白**：白卡压在亮壁纸上，
    // 白描边等于没画，卡片整个糊进背景里。Cleo 的原话是「刚才的黑色主题，
    // 卡片就很好看，边缘亮亮的，能看出来是卡片，现在这个就有点模糊了」
    // ——她夸的正是暗底那道亮边，缺的是浅底这一侧的对应物。
    //
    // 现在两边都有边了，但不再是 `Border.all` 那种四边一样亮的圈——
    // 见 [_RimPainter]。
    final glass = ClipRRect(
      borderRadius: widget.borderRadius,
      child: BackdropFilter(
        // 模糊 + 提饱和度，顺序是「先糊再提」。
        //
        // 只糊不提，背景会被搅成一团灰——那是「脏」，不是「透」。
        // iOS 那层玻璃好看，一大半是因为它在模糊之后把彩度拉回来了，
        // 所以底下的颜色还活着。
        //
        // 原来这里是拿一层 5% 的强调色硬叠上去凑（见下面的 widget.tint），
        // 那是替代品：它给整张卡片染同一个颜色，而真饱和度是让**背景
        // 本来的颜色**变鲜艳。区别在有多张不同颜色的东西透上来的时候。
        filter: _filter(MediaQuery.devicePixelRatioOf(context)),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: _alpha),
            borderRadius: widget.borderRadius,
          ),
          // passthrough：把外面的约束原样传给内容，
          // 保持换成 Stack 之前 DecoratedBox 的布局行为。
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.tint == null
                  ? widget.child
                  // 补彩度：极淡的一层背景色叠上去，让透过来的粉/蓝是活的。
                  // 0.05 是上限——再高就从「晕染」变成「染色」，卡片会显脏。
                  : DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.tint!.withValues(alpha: 0.05),
                      borderRadius: widget.borderRadius,
                    ),
                    child: widget.child,
                  ),
              // 颗粒。真磨砂玻璃是散射的，表面有细微的不匀；
              // 完美平滑的高斯模糊，眼睛会读成塑料。
              //
              // 压在文字**上面**是故意的——玻璃在字的这一侧，
              // 垫在下面就等于把颗粒也糊进背景里，看不见。
              //
              // ⚠️ `scale: dpr` 这一下是关键。
              //
              // 第一版没写，于是纹理按**逻辑像素**平铺——在 3x 屏上，
              // 一个噪点被画成 3×3 个物理像素。Cleo 的原话是
              // 「这颗粒有力气，像薄荷牙膏里的小颗粒」：本来想要细砂纸，
              // 出来是粗砂糖。
              //
              // 按设备像素比缩小之后，一个噪点正好一个物理像素，
              // 才是「表面不匀」而不是「撒了一层东西」。
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.25,
                    child: Image(
                      image: ExactAssetImage(
                        'assets/glass-noise.png',
                        scale: MediaQuery.devicePixelRatioOf(context),
                      ),
                      repeat: ImageRepeat.repeat,
                      fit: BoxFit.none,
                      alignment: Alignment.topLeft,
                      // 缩小之后仍然用最近邻：插值会把噪点糊成灰雾，
                      // 那就白加了。
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
              ),
              // 边缘高光。必须画在最上层：它是玻璃的边，不是背景的边。
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _RimPainter(
                      borderRadius: widget.borderRadius,
                      lightGlass: widget.lightBackground,
                      tone: tone,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (!widget.lightBackground) return glass;

    // 阴影必须画在 ClipRRect **外面**，不然被裁掉。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: widget.borderRadius,
        boxShadow:
            widget.floating
                ? AppShadow.softenFloating(false)
                : AppShadow.soften(false),
      ),
      child: glass,
    );
  }
}

/// 提饱和度的颜色矩阵。
///
/// [s] = 1 是原样，大于 1 变鲜艳。1.8 接近 iOS 材质的观感。
///
/// 亮度系数用 Rec.709（0.2126 / 0.7152 / 0.0722）——保持亮度不变、只拉开
/// 彩度，这样**不会影响正文的对比度**。玻璃的可读性是靠 [glassAlpha] 二分
/// 算出来的，那一套的前提是亮度不被这一层动过。
ui.ColorFilter _saturate(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final r = (1 - s) * lr, g = (1 - s) * lg, b = (1 - s) * lb;
  return ui.ColorFilter.matrix(<double>[
    r + s,
    g,
    b,
    0,
    0,
    r,
    g + s,
    b,
    0,
    0,
    r,
    g,
    b + s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}

/// 玻璃的边。
///
/// ## 为什么不用 `Border.all`
///
/// `Border.all` 四条边一样亮。真玻璃不是——光从上面来，所以**左上亮、
/// 右下暗**。四边等亮的结果，眼睛读出来的是「一个描了边的矩形」，
/// 不是「一块有厚度的东西」。
///
/// Cleo 看着深色玻璃说「感觉这黑色也像卡片其实」，说的就是这个：
/// 半透明是有了，但没有立起来。
///
/// ## 亮边和暗边一起画
///
/// 只加亮边会变成「发光的框」。**右下那道极淡的暗边才是厚度的来源**——
/// 有背光的一侧，才看得出这块东西有两个面。
///
/// ## 描边画在内侧
///
/// `strokeWidth` 的一半会落在路径外，被 `ClipRRect` 裁掉，于是看起来
/// 只有半格粗、还发虚。往里缩半格，整条边才是实的。
class _RimPainter extends CustomPainter {
  final BorderRadius borderRadius;
  final bool lightGlass;
  final AppTone tone;

  const _RimPainter({
    required this.borderRadius,
    required this.lightGlass,
    required this.tone,
  });

  /// 亮边强度。浅色玻璃底子本来就亮，白边要更用力才看得出来；
  /// 深色玻璃上一点点就够，多了就成了发光的框。
  ///
  /// 2026-09-08 提了一档（0.55/0.22 → 0.70/0.34）：加了饱和度之后卡片
  /// 本身变鲜艳了，原来那道边相对就淡下去，卡片边界糊在花壁纸里。
  /// **边要跟着卡片一起亮**，不然「清透」会变成「糊」。
  double get _highlight => lightGlass ? 0.70 : 0.34;

  /// 暗边强度。深色玻璃上的暗边几乎看不见（底子已经很暗），
  /// 所以主要是浅色那侧在用。
  double get _shade => lightGlass ? 0.10 : 0.07;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 1.0;
    final rect = Offset.zero & size;
    // 往里缩半格：不缩的话外侧半格会被 ClipRRect 裁掉，边看着发虚。
    final rrect = borderRadius.toRRect(rect).deflate(w / 2);

    final light = tone.shift(const Color(0xFFFFFDFB));
    final dark = tone.shift(const Color(0xFF14100D));

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = ui.Gradient.linear(
          rect.topLeft,
          rect.bottomRight,
          [
            light.withValues(alpha: _highlight),
            light.withValues(alpha: _highlight * 0.25),
            dark.withValues(alpha: _shade * 0.3),
            dark.withValues(alpha: _shade),
          ],
          // 亮的那头收得快、暗的那头拖得长：光是打在一个角上的，
          // 平均分配会变成一条从亮到暗的均匀渐变，那又回到「描了边的矩形」。
          const [0.0, 0.32, 0.7, 1.0],
        ),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.lightGlass != lightGlass || old.borderRadius != borderRadius;
}
