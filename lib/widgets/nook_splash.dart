import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// 开屏：留一盏灯。
///
/// nook 是房间里的一个角落。很晚回来，有人给你留了一盏灯——开屏只做这一件事：
/// 黑暗里画出一个墙角，角落里的光亮起来，门牌那么小的 nook 浮出来。
/// 光跟着真实的时间走：早上是窗户投进来的一块日光，傍晚是拉长了的斜阳，深夜是那盏台灯。
///
/// 2026-09-15 小克出的方案，Cleo 在手机上看过原型选的它。原型是 scratchpad 里的
/// nook-splash.html（artifact 链接记在记忆 nook-identity 里），这里的几何、颜色、
/// 节奏都是照着那一版搬的，比例全按屏幕宽高算。她否掉过的：星星、糖果色、粗线、
/// 一屏塞太多东西——改的时候别往回走。
///
/// 盖在整个 App 上面：底下的首页照常建好，开屏淡出时露出来的就是画好的第一帧。
class NookSplash extends StatefulWidget {
  const NookSplash({super.key, required this.onDone, this.now});

  /// 淡出完了。调用方把它从树上拿掉。
  final VoidCallback onDone;

  /// 测试用：定住「现在几点」。
  final DateTime? now;

  /// 墙角画完、光亮起来、nook 浮出来、停一下：到这里为止。
  static const play = Duration(milliseconds: 1600);

  /// 然后淡出，露出底下的 App。
  static const fade = Duration(milliseconds: 320);

  @override
  State<NookSplash> createState() => _NookSplashState();
}

enum SplashTime { morning, evening, night }

/// 5–15 点早上、15–19 点傍晚、其余深夜。纯函数。
SplashTime splashTimeFor(int hour) => hour >= 5 && hour < 15
    ? SplashTime.morning
    : hour >= 15 && hour < 19
    ? SplashTime.evening
    : SplashTime.night;

class SplashTone {
  const SplashTone({
    required this.bright,
    required this.bgTop,
    required this.bgBottom,
    required this.line,
    required this.text,
    required this.light,
  });

  final bool bright;
  final Color bgTop, bgBottom, line, text, light;

  static const morning = SplashTone(
    bright: true,
    bgTop: Color(0xFFEFEEE9),
    bgBottom: Color(0xFFE1E0DA),
    line: Color(0xFFB3AEA2),
    text: Color(0xFF34312B),
    light: Color(0xFFF6DB98),
  );
  static const evening = SplashTone(
    bright: false,
    bgTop: Color(0xFF2C2433),
    bgBottom: Color(0xFF19141F),
    line: Color(0xFF5E5066),
    text: Color(0xFFF5E3D4),
    light: Color(0xFFF09F6C),
  );
  static const night = SplashTone(
    bright: false,
    bgTop: Color(0xFF16161C),
    bgBottom: Color(0xFF0C0C11),
    line: Color(0xFF403F4D),
    text: Color(0xFFEFE0C8),
    light: Color(0xFFE8B373),
  );

  static SplashTone of(SplashTime t) => switch (t) {
    SplashTime.morning => morning,
    SplashTime.evening => evening,
    SplashTime.night => night,
  };
}

class _NookSplashState extends State<NookSplash>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;
  late final SplashTime _time;
  bool _leaving = false;

  /// 光那一层先画好存成图，每一帧只调透明度（和日光的位置）。按尺寸缓存。
  ui.Image? _light;
  Size? _lightSize;
  double? _lightDpr;
  List<_Dust> _dust = const [];

  @override
  void initState() {
    super.initState();
    _time = splashTimeFor((widget.now ?? DateTime.now()).hour);
    _ticker = createTicker((d) {
      setState(() => _elapsed = d);
      if (d >= NookSplash.play) _leave();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开了「减少动画」：不演，直接停在最后一帧，稍等就淡出。
    if (MediaQuery.disableAnimationsOf(context)) {
      if (!_ticker.isActive && !_leaving) {
        _elapsed = NookSplash.play;
        Future.delayed(const Duration(milliseconds: 500), _leave);
      }
    } else if (!_ticker.isActive && !_leaving) {
      _ticker.start();
    }
  }

  void _leave() {
    if (_leaving || !mounted) return;
    _ticker.stop();
    setState(() {
      _leaving = true;
      // 点一下跳过：直接定到最后一帧再淡出，别从半截墙角淡出去。
      if (_elapsed < NookSplash.play) _elapsed = NookSplash.play;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _light?.dispose();
    super.dispose();
  }

  void _ensureLight(Size size, double dpr, SplashTone tone) {
    if (_light != null && _lightSize == size && _lightDpr == dpr) return;
    _light?.dispose();
    final geo = _Geo(size);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec)..scale(dpr);
    if (_time == SplashTime.night) {
      _paintLamp(c, geo, tone, dpr);
    } else {
      _paintSun(c, geo, tone, _time == SplashTime.evening, dpr);
    }
    final pic = rec.endRecording();
    _light = pic.toImageSync(
      (size.width * dpr).ceil(),
      (size.height * dpr).ceil(),
    );
    pic.dispose();
    _lightSize = size;
    _lightDpr = dpr;
    _dust = _time == SplashTime.night ? const [] : _Dust.scatter(geo);
  }

  @override
  Widget build(BuildContext context) {
    final tone = SplashTone.of(_time);
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (!size.isEmpty) _ensureLight(size, dpr, tone);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: tone.bright
          ? SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            )
          : SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
            ),
      child: AnimatedOpacity(
        opacity: _leaving ? 0 : 1,
        duration: NookSplash.fade,
        curve: Curves.easeOut,
        onEnd: () {
          if (_leaving) widget.onDone();
        },
        child: IgnorePointer(
          ignoring: _leaving,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _leave,
            child: Semantics(
              label: 'Nook',
              button: true,
              onTapHint: '跳过开屏',
              child: CustomPaint(
                size: Size.infinite,
                painter: _SplashPainter(
                  t: _elapsed.inMicroseconds / 1000,
                  tone: tone,
                  sun: _time != SplashTime.night,
                  light: _light,
                  dpr: dpr,
                  dust: _dust,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── 几何 ───────────────────────────

double _clamp(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
double _easeOut(double p) => 1 - math.pow(1 - p, 3).toDouble();
double _easeInOutSine(double p) => -(math.cos(math.pi * p) - 1) / 2;

/// 墙角在哪：一竖一横两条细线，在左下角碰上。
class _Geo {
  _Geo(this.size)
    : w = size.width,
      h = size.height,
      wallX = size.width * 0.22,
      wallTop = size.height * 0.28,
      floorY = size.height * 0.58,
      floorEnd = size.width * 0.84;

  final Size size;
  final double w, h, wallX, wallTop, floorY, floorEnd;
}

const _tLight0 = 420.0;
const _tText0 = 850.0;

// ─────────────────────────── 光 ───────────────────────────

/// 深夜：一团从灯那一点晕开的光，外加灯本身一小点暖白、地上一小片反光。
///
/// ⚠️ 原型第一版在墙角里面单独裁了一块更亮的光，裁出一条方方的硬边，看着像污渍。
/// 只留从一点晕开的光。
void _paintLamp(Canvas c, _Geo g, SplashTone tone, double dpr) {
  final w = g.w;
  final cx = g.wallX + w * 0.12, cy = g.floorY - w * 0.2;
  final center = Offset(cx, cy);
  final all = Offset.zero & g.size;
  final soft = math.max(2 / dpr, w * 0.008);
  c.saveLayer(
    all,
    Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: soft, sigmaY: soft),
  );
  c.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.radial(
        center,
        w * 0.46,
        [
          tone.light.withValues(alpha: 0.55),
          tone.light.withValues(alpha: 0.32),
          tone.light.withValues(alpha: 0.08),
          tone.light.withValues(alpha: 0),
        ],
        const [0, 0.18, 0.55, 1],
      ),
  );
  c.drawRect(
    Rect.fromCircle(center: center, radius: w * 0.05),
    Paint()
      ..shader = ui.Gradient.radial(center, w * 0.035, [
        const Color(0xFFFFF4DF).withValues(alpha: 0.95),
        tone.light.withValues(alpha: 0),
      ]),
  );
  c.save();
  c.translate(cx + w * 0.04, g.floorY + w * 0.02);
  c.scale(1, 0.12);
  c.drawRect(
    Rect.fromLTWH(-w, -w, w * 2, w * 2),
    Paint()
      ..shader = ui.Gradient.radial(Offset.zero, w * 0.26, [
        tone.light.withValues(alpha: 0.22),
        tone.light.withValues(alpha: 0),
      ]),
  );
  c.restore();
  c.restore();
}

/// 早上 / 傍晚：窗户投进来的那块光。
///
/// ⚠️ 原型第一版是一整块平涂 + 一圈一样的糊边——像贴在墙上的一张黄纸。
/// 真的窗光：沿光线方向由亮到暗；边基本清楚，外面一圈淡的半影；
/// 旁边的墙被照得微微发暖；空气里一道几乎看不见的光柱。
void _paintSun(Canvas c, _Geo g, SplashTone tone, bool evening, double dpr) {
  final w = g.w, h = g.h;
  final all = Offset.zero & g.size;
  final strength = evening ? 0.72 : 0.9;

  void patch() {
    c.saveLayer(all, Paint());
    final along = Paint()
      ..shader = ui.Gradient.linear(
        Offset(g.wallX + w * 0.45, g.wallTop),
        Offset(g.wallX, h * 0.66),
        [
          tone.light.withValues(alpha: strength),
          tone.light.withValues(alpha: strength * 0.5),
        ],
      );
    final lean = evening ? w * 0.16 : w * 0.1;
    final top = evening
        ? g.wallTop + (g.floorY - g.wallTop) * 0.35
        : g.wallTop + (g.floorY - g.wallTop) * 0.08;
    final x0 = g.wallX + (evening ? w * 0.16 : w * 0.1);
    final width = evening ? w * 0.2 : w * 0.24;
    final reach = evening ? w * 0.42 : w * 0.2;
    final drop = evening ? h * 0.045 : h * 0.075;
    // 墙上一块斜的平行四边形，接着落到地上。
    c.drawPath(
      Path()
        ..moveTo(x0, top)
        ..lineTo(x0 + width, top - h * 0.02)
        ..lineTo(x0 + width + lean, g.floorY)
        ..lineTo(x0 + lean, g.floorY)
        ..close(),
      along,
    );
    c.drawPath(
      Path()
        ..moveTo(x0 + lean, g.floorY)
        ..lineTo(x0 + width + lean, g.floorY)
        ..lineTo(x0 + width + lean + reach, g.floorY + drop * 0.9)
        ..lineTo(x0 + lean + reach * 0.85, g.floorY + drop)
        ..close(),
      along,
    );
    // 窗框：一竖一横两道暗缝，一眼就是窗户投进来的光。
    c.drawPath(
      Path()
        ..moveTo(x0 + width / 2, top - h * 0.01)
        ..lineTo(x0 + width / 2 + lean, g.floorY)
        ..moveTo(x0 + lean * 0.45, (top + g.floorY) / 2)
        ..lineTo(x0 + width + lean * 0.45, (top + g.floorY) / 2 - h * 0.01),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.012
        ..color = Colors.black.withValues(alpha: 0.55)
        ..blendMode = BlendMode.dstOut,
    );
    c.restore();
  }

  // 半影：糊得开、淡。
  final wide = w * 0.016;
  c.saveLayer(
    all,
    Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..imageFilter = ui.ImageFilter.blur(sigmaX: wide, sigmaY: wide),
  );
  patch();
  c.restore();
  // 光斑本身：边基本清楚。
  final edge = math.max(1 / dpr, w * 0.003);
  c.saveLayer(
    all,
    Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: edge, sigmaY: edge),
  );
  patch();
  c.restore();

  // 墙被照得微微发暖。亮底上大面积淡渐变会出色阶纹，早上压淡。
  final m = Offset(g.wallX + w * 0.3, g.floorY - h * 0.08);
  c.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.radial(m, w * 0.55, [
        tone.light.withValues(alpha: evening ? 0.14 : 0.1),
        tone.light.withValues(alpha: 0),
      ]),
  );

  // 空气里的光柱，指着光从哪来。
  c.drawPath(
    Path()
      ..moveTo(w * 1.05, -h * 0.02)
      ..lineTo(w * 1.15, h * 0.12)
      ..lineTo(g.wallX + w * (evening ? 0.6 : 0.46), g.floorY)
      ..lineTo(g.wallX + w * (evening ? 0.2 : 0.12), g.floorY - h * 0.2)
      ..close(),
    Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.04)
      ..shader = ui.Gradient.linear(
        Offset(w, 0),
        Offset(g.wallX + w * 0.2, g.floorY),
        [
          tone.light.withValues(alpha: evening ? 0.1 : 0.05),
          tone.light.withValues(alpha: 0),
        ],
      ),
  );
}

/// 光柱里飘着的几粒浮尘。不是星星——阳光照进屋里真的看得见这个。
class _Dust {
  const _Dust(this.x, this.y, this.r, this.a, this.phase);
  final double x, y, r, a, phase;

  static List<_Dust> scatter(_Geo g) {
    final rand = math.Random(57);
    return List.generate(9, (_) {
      final f = rand.nextDouble();
      return _Dust(
        g.w * 0.95 +
            (g.wallX + g.w * 0.35 - g.w * 0.95) * f +
            (rand.nextDouble() - 0.5) * g.w * 0.12,
        g.h * 0.08 +
            (g.floorY - g.h * 0.12 - g.h * 0.08) * f +
            (rand.nextDouble() - 0.5) * g.h * 0.05,
        0.7 + rand.nextDouble() * 1.1,
        0.3 + rand.nextDouble() * 0.5,
        rand.nextDouble() * math.pi * 2,
      );
    });
  }
}

// ─────────────────────────── 每一帧 ───────────────────────────

class _SplashPainter extends CustomPainter {
  _SplashPainter({
    required this.t,
    required this.tone,
    required this.sun,
    required this.light,
    required this.dpr,
    required this.dust,
  });

  /// 毫秒。
  final double t;
  final SplashTone tone;
  final bool sun;
  final ui.Image? light;
  final double dpr;
  final List<_Dust> dust;

  @override
  void paint(Canvas canvas, Size size) {
    final g = _Geo(size);
    final w = g.w;
    final all = Offset.zero & size;

    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          tone.bgTop,
          tone.bgBottom,
        ]),
    );

    // 光：台灯先闪一下再亮稳；日光从窗那边慢慢移进来。
    final k = t - _tLight0;
    var intensity = 0.0;
    var slide = 0.0;
    if (k > 0) {
      if (sun) {
        intensity = _easeInOutSine(_clamp(k / 720));
        slide = w * 0.05 * (1 - intensity);
      } else {
        intensity = _easeOut(_clamp(k / 580)) * (k > 90 && k < 150 ? 0.5 : 1);
      }
    }
    final img = light;
    if (intensity > 0 && img != null) {
      canvas.save();
      canvas.scale(1 / dpr);
      final at = Offset(slide * dpr, 0);
      canvas.drawImage(
        img,
        at,
        Paint()
          ..color = Colors.white.withValues(alpha: intensity)
          ..blendMode = tone.bright ? BlendMode.multiply : BlendMode.screen
          ..filterQuality = FilterQuality.low,
      );
      if (tone.bright) {
        // 白天的光在亮底上要「提亮」不是「压暗」：再薄薄叠一层正常混合。
        canvas.drawImage(
          img,
          at,
          Paint()
            ..color = Colors.white.withValues(alpha: intensity * 0.55)
            ..filterQuality = FilterQuality.low,
        );
      }
      canvas.restore();
    }

    final dustColor = tone.bright ? tone.light : const Color(0xFFFFE2C6);
    for (final d in dust) {
      final a = intensity * d.a * (0.6 + 0.4 * math.sin(t * 0.002 + d.phase));
      if (a <= 0) continue;
      canvas.drawCircle(
        Offset(
          d.x + math.sin(t * 0.0006 + d.phase) * w * 0.02,
          d.y + math.sin(t * 0.00045 + d.phase * 1.7) * size.height * 0.012,
        ),
        d.r,
        Paint()..color = dustColor.withValues(alpha: a),
      );
    }

    // 墙角：一竖一横两条细线，在左下角碰上。线的远端淡出，像从黑里长出来。
    final stroke = math.max(1 / dpr, 1.1);
    final vp = _easeOut(_clamp(t / 260));
    final hp = _easeOut(_clamp((t - 200) / 280));
    if (vp > 0) {
      canvas.drawLine(
        Offset(g.wallX, g.floorY),
        Offset(g.wallX, g.floorY - (g.floorY - g.wallTop) * vp),
        Paint()
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
            Offset(0, g.wallTop),
            Offset(0, g.floorY),
            [
              tone.line.withValues(alpha: 0),
              tone.line.withValues(alpha: 0.9),
              tone.line,
            ],
            const [0, 0.35, 1],
          ),
      );
    }
    if (hp > 0) {
      canvas.drawLine(
        Offset(g.wallX, g.floorY),
        Offset(g.wallX + (g.floorEnd - g.wallX) * hp, g.floorY),
        Paint()
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..shader = ui.Gradient.linear(
            Offset(g.wallX, 0),
            Offset(g.floorEnd, 0),
            [
              tone.line,
              tone.line.withValues(alpha: 0.85),
              tone.line.withValues(alpha: 0),
            ],
            const [0, 0.7, 1],
          ),
      );
    }

    // nook：门牌那么小，在光里浮出来。
    final tp = _easeOut(_clamp((t - _tText0) / 420));
    if (tp > 0) {
      final fs = w * 0.12;
      final text = TextPainter(
        text: TextSpan(
          text: 'nook',
          style: TextStyle(
            fontFamily: 'FrauncesNook',
            fontFamilyFallback: const ['serif'],
            fontSize: fs,
            fontWeight: FontWeight.w400,
            letterSpacing: fs * 0.02,
            color: tone.text.withValues(alpha: tp),
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final baseline = g.floorY - w * 0.075 + fs * 0.12 * (1 - tp);
      text.paint(
        canvas,
        Offset(
          g.wallX + w * 0.085,
          baseline -
              text.computeDistanceToActualBaseline(TextBaseline.alphabetic),
        ),
      );
      text.dispose();
    }
  }

  @override
  bool shouldRepaint(_SplashPainter old) =>
      old.t != t || old.light != light || old.tone != tone || old.dpr != dpr;
}
