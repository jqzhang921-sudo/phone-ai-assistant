import 'package:flutter/material.dart';
import 'app_shape.dart';
import 'oklab.dart';

/// 整套配色的「色调」：往哪个色相转、彩度收多少。
///
/// ## 它解决的是什么
///
/// 玻璃主题第一版其实是「棕色主题 + 模糊」。卡片透出粉色壁纸，气泡和实色块
/// 却还留在暖棕系里，两套颜色摆在一起——Cleo 的原话是「这个深色和这个兔子
/// 背景不太搭」「信的颜色有点出戏」。要拆开的不是「糊不糊」这一维，
/// 是**这一整套颜色到底属于谁**。
///
/// 所以这里只做一件事：把徽标棕那一族整体旋到背景图的色相上去。
/// 对比度、那唯一一档次级灰、明度层级全部原样保留，只有色相变了。
///
/// ## 两件必须一起做对的事
///
/// 1. **在 OKLCH 里转，不在 HSL 里转。** HSL 的饱和度不是感知量：`#D9B48F`
///    的 0.49 是柔的浅棕，色相转到绿、饱和度照抄，出来是 `#9AC85E` 一块
///    刺眼的草绿。OKLCH 的彩度各色相之间可比，转过去还是同样的「花」。
///    详见 `oklab.dart`。
/// 2. **相对亮度二分回原值。** 只转色相不管亮度的话，白字压 primary 的对比度
///    会从 5.6:1 漂到 4.0:1——把 Cleo 调了很久的一套对比度悄悄冲掉，而且只在
///    某几个背景下坏，事后根本查不出是哪一步弄的。
///
/// 注意 OKLab 的 L 和 WCAG 相对亮度不是一回事，所以不能只保住 L 就完事，
/// 得真的二分。
class AppTone extends ThemeExtension<AppTone> {
  /// 色相偏移（度）。0 = 不转。
  final double hueDelta;

  /// 彩度倍率。1 = 不动，见 [neutral]。
  final double satScale;

  /// 同一个 tone 下同一个颜色永远转出同一个结果，算一次就够。
  /// 二分本身不贵，但气泡是每帧每条都要问一次的。
  final Map<int, Color> _cache = {};

  AppTone({this.hueDelta = 0, this.satScale = 1});

  /// 什么都不动：没开玻璃主题时用它，出来就是原来那套棕。
  static final AppTone none = AppTone();

  /// 灰度背景（图里解不出色相）用的中性色调。
  ///
  /// 退回徽标棕是错的：黑白照片配一块棕色强调，和粉色壁纸上冒出棕色是同一种
  /// 「两套东西凑在一起」。整套降彩度出来是一副中性玻璃，看着像是故意的。
  /// 0.35 是「还看得出偏暖，但不再主张自己是棕色」那一档。
  static final AppTone neutral = AppTone(satScale: 0.35);

  /// 把整套配色转到 [accent] 的色相上。[accent] 来自
  /// `BackgroundProvider.backgroundAccent`。
  factory AppTone.towards(Color accent) =>
      AppTone(hueDelta: (toOklch(accent).h - _brandHue + 360) % 360);

  static final double _brandHue = toOklch(AppTheme.brandBrown).h;

  static AppTone of(BuildContext context) =>
      Theme.of(context).extension<AppTone>() ?? none;

  bool get isIdentity => hueDelta.abs() < 0.01 && (satScale - 1).abs() < 0.001;

  /// 转色相、锁亮度。
  ///
  /// ⚠️ **只喂写死的原始色，别喂 `scheme.xxx`**——ColorScheme 里的颜色在
  /// 建主题时已经转过一遍了，再转一次就是转两次，会跑到别的色相上去。
  Color shift(Color c) {
    if (isIdentity) return c;
    return _cache.putIfAbsent(c.toARGB32(), () => _shift(c));
  }

  Color _shift(Color c) {
    final lch = toOklch(c);
    // 真中性色（纯白、纯黑、纯灰）转色相是恒等变换，别白跑一趟二分。
    if (lch.c < 0.002) return c;

    final target = c.computeLuminance();
    final hue = (lch.h + hueDelta) % 360;
    final chroma = lch.c * satScale;

    // 固定色相/彩度时相对亮度对 OKLab 的 L 单调递增（L=0 是黑、L=1 是白），
    // 二分一定收敛。18 次到 1/262144，远超 8 位色深分得出的精度。
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 18; i++) {
      final mid = (lo + hi) / 2;
      if (fromOklch(mid, chroma, hue).computeLuminance() < target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return fromOklch((lo + hi) / 2, chroma, hue, alpha: c.a);
  }

  /// 在 [background] 上选一个读得清的前景色：深墨和纯白各算一次对比度，
  /// 取高的那个。
  ///
  /// ⚠️ 别退回写死的 `onPrimary`。栖息页那张信卡踩过：底色是运行时从背景图
  /// 算出来的强调色（明度锁在 V=0.85，很亮），前景却写死白色——白字压上去
  /// 实测只有 1.6–2.6:1，字基本看不见；同一块底换成深墨是 7–11:1。
  /// **底色是运行时算的，前景就不能是编译期定死的。**
  Color inkOn(Color background) {
    final ink = shift(_ink);
    final l = background.computeLuminance();
    final withInk = (l + 0.05) / (ink.computeLuminance() + 0.05);
    final withWhite = 1.05 / (l + 0.05);
    return withInk >= withWhite ? ink : Colors.white;
  }

  static const Color _ink = Color(0xFF2A211A);

  @override
  AppTone copyWith({double? hueDelta, double? satScale}) => AppTone(
    hueDelta: hueDelta ?? this.hueDelta,
    satScale: satScale ?? this.satScale,
  );

  /// 换壁纸时整套配色跟着渐变过去，而不是啪一下跳。MaterialApp 内部的
  /// AnimatedTheme 会连扩展一起插值。
  @override
  AppTone lerp(covariant AppTone? other, double t) {
    if (other == null) return this;
    // 色相走短弧：从 350° 到 10° 该经过 0°，不是横穿整个色环。
    var delta = other.hueDelta - hueDelta;
    if (delta > 180) delta -= 360;
    if (delta < -180) delta += 360;
    return AppTone(
      hueDelta: (hueDelta + delta * t + 360) % 360,
      satScale: satScale + (other.satScale - satScale) * t,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppTone &&
      other.hueDelta == hueDelta &&
      other.satScale == satScale;

  @override
  int get hashCode => Object.hash(hueDelta, satScale);
}

/// 温暖棕主题：配色跟随 Cleo 徽标规范（主色 #8B5E34，底色奶白 #FDF8F1），
/// 浅深两套。
///
/// 三条不要破的规则：
///
/// 1. **只有一档次级灰**（浅 `#787168` / 深 `#948A80`）。想让一行更弱，
///    用字号和字重，不要再往下调对比度 —— `#8C857B` / `#A8A096` 这类
///    在 `#FDF8F1` 上只有 2.4–3.4:1，白天在手机上根本看不清。
/// 2. **卡片一律纯白，层次靠阴影不靠描边。** 描边是「碎线太多」的主因，
///    所以 cardTheme 不再带 side，outlineVariant 压到 5% 只给组内分隔线用。
///    阴影要自己画（Material 的 elevation 出来是灰的）。
/// 3. **深色模式不画阴影**，层次改用 `#171310` → `#251F1A` 的明度差；
///    主色从棕换成浅棕，棕色在暗底上看不见。
class AppTheme {
  AppTheme._();

  /// 徽标的温暖棕。整套配色的基准色相就是它的色相（约 29°），
  /// [AppTone.towards] 拿它算「要转多少度」，所以这里和 [_scheme] 里的
  /// primary 必须是同一个值——分叉了色相就会转错。
  static const Color brandBrown = Color(0xFF8B5E34);

  /// 页面底色（奶白）。聊天背景预设 `light` 也取这个值——
  /// 那层预设是整屏铺在主题上面的，写死颜色会把 ColorScheme.surface 盖掉。
  static const Color surfaceLight = Color(0xFFFDF8F1);

  /// 页面底色（暖黑，不用纯黑）。聊天背景预设 `dark` 同上。
  static const Color surfaceDark = Color(0xFF171310);

  /// [titleSerif] true 时 AppBar 标题用衬线体（Noto Serif SC），false 用默认黑体。
  /// [tone] 决定整套配色转到哪个色相，默认 [AppTone.none]（原来那套棕）。
  static ThemeData lightWith({required bool titleSerif, AppTone? tone}) =>
      _build(Brightness.light, titleSerif, tone ?? AppTone.none);
  static ThemeData darkWith({required bool titleSerif, AppTone? tone}) =>
      _build(Brightness.dark, titleSerif, tone ?? AppTone.none);

  static ColorScheme _scheme(Brightness brightness, AppTone tone) {
    final light = brightness == Brightness.light;
    // 每个 token 都过一遍 tone。**报错色是唯一的例外**，见下面。
    Color t(Color c) => tone.shift(c);
    return ColorScheme(
      brightness: brightness,
      // 全 App 唯一的强调色：徽标的温暖棕。深色下必须换成浅棕，
      // 否则整块主色会沉进暗底里看不见。
      primary: t(light ? brandBrown : const Color(0xFFD9B48F)),
      onPrimary: t(light ? Colors.white : const Color(0xFF2A211A)),
      // 选中态的淡底。深色用 18% alpha 的浅棕，不用实色——
      // 实色主色做选中底太重，会和顶部的棕色元素抢。
      primaryContainer: t(
        light ? const Color(0xFFEFE3D4) : const Color(0x2ED9B48F),
      ),
      onPrimaryContainer: t(
        light ? const Color(0xFF6F4A28) : const Color(0xFFEBD9C4),
      ),
      // 徽标的辅助浅棕。它是「装饰用的浅色块」，不是前景色——
      // 拿它当图标或文字色放在奶白底上只有 1.5:1，别这么用。
      secondary: t(const Color(0xFFD9B48F)),
      onSecondary: t(
        light ? const Color(0xFF3B2A17) : const Color(0xFF2A211A),
      ),
      secondaryContainer: t(
        light ? const Color(0xFFF3E7D8) : const Color(0xFF3A2F26),
      ),
      onSecondaryContainer: t(
        light ? const Color(0xFF5A4429) : const Color(0xFFEBD9C4),
      ),
      // 第三档不再是「更浅一点的灰」，直接对齐唯一那档次级灰
      tertiary: t(light ? const Color(0xFF787168) : const Color(0xFF948A80)),
      onTertiary: t(light ? Colors.white : const Color(0xFF171310)),
      tertiaryContainer: t(
        light ? const Color(0xFFEFEDE9) : const Color(0xFF2B2521),
      ),
      onTertiaryContainer: t(
        light ? const Color(0xFF3A342E) : const Color(0xFFE3D9CE),
      ),
      // ⚠️ 报错色**不过 t()**：红色必须是红色。整套转色相时它跟着转，
      // 蓝色背景下删除确认就成了一块蓝，「危险」那层意思当场丢掉。
      error: light ? const Color(0xFFBA1A1A) : const Color(0xFFFFB4AB),
      onError: light ? Colors.white : const Color(0xFF690005),
      errorContainer: light ? const Color(0xFFFFDAD6) : const Color(0xFF93000A),
      onErrorContainer:
          light ? const Color(0xFF410002) : const Color(0xFFFFDAD6),
      // 底色奶白、卡片纯白：两者只差一点亮度，所以层次全压在阴影上。
      // 深色反过来——不画阴影，靠 #171310 → #251F1A 这一档明度差。
      surface: t(light ? surfaceLight : surfaceDark),
      onSurface: t(
        light ? const Color(0xFF1A1512) : const Color(0xFFF2EAE0),
      ),
      surfaceContainerLowest: t(
        light ? const Color(0xFFFFFFFF) : const Color(0xFF110E0B),
      ),
      surfaceContainerLow: t(
        light ? const Color(0xFFFFFFFF) : const Color(0xFF251F1A),
      ),
      surfaceContainer: t(
        light ? const Color(0xFFFFFFFF) : const Color(0xFF251F1A),
      ),
      surfaceContainerHigh: t(
        light ? const Color(0xFFF5F0E8) : const Color(0xFF2E2721),
      ),
      // 输入框底
      surfaceContainerHighest: t(
        light ? const Color(0xFFEFEDE9) : const Color(0xFF383029),
      ),
      // 唯一的次级灰：副标题、meta、计数、导航标签、时间戳全走这一个。
      // 浅色约 4.6:1，深色约 4.7:1。
      onSurfaceVariant: t(
        light ? const Color(0xFF787168) : const Color(0xFF948A80),
      ),
      outline: t(light ? const Color(0xFF8C8378) : const Color(0xFF8A8079)),
      // 只用于组内分隔线（浅 5% / 深 7%）。它不再是描边色——
      // 谁拿它 Border.all 都会得到一条几乎看不见的线，这是故意的。
      outlineVariant: t(
        light ? const Color(0x0D1A1512) : const Color(0x12F2EAE0),
      ),
      shadow: t(light ? const Color(0x261A1512) : Colors.black),
      scrim: t(light ? const Color(0x571A1512) : const Color(0x8C000000)),
      inverseSurface: t(
        light ? const Color(0xFF302823) : const Color(0xFFF2EAE0),
      ),
      onInverseSurface: t(
        light ? const Color(0xFFF7F1E9) : const Color(0xFF171310),
      ),
      inversePrimary: t(light ? const Color(0xFFD9B48F) : brandBrown),
    );
  }

  static ThemeData _build(
    Brightness brightness,
    bool titleSerif,
    AppTone tone,
  ) {
    final scheme = _scheme(brightness, tone);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
      // tone 也挂进主题：气泡、玻璃本体、水印那几个颜色不属于 ColorScheme，
      // 但同样要跟着转。它们通过 `AppTone.of(context)` 自己取。
      extensions: <ThemeExtension<dynamic>>[tone],
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        // 宋体开关作用在这里
        titleTextStyle: TextStyle(
          fontFamily: titleSerif ? 'NotoSerifSC' : null,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0, // 阴影自己画，Material 的 elevation 出来偏灰
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color:
                selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          );
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      // 字阶：跨度从原来的 22–12 拉到 29–11。正文一律 w400，
      // 只有标题和标签 w500+——之前字重全挤在 600–700，等于没有重点。
      textTheme: base.textTheme.copyWith(
        // 页面大标题：「晚上好，Cleo」「我的书架」「栖息」
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 29,
          fontWeight: FontWeight.w700,
          height: 1.1,
          color: scheme.onSurface,
        ),
        // 内页标题：「信」「日记」「一隅」（AppBar 走上面的 titleTextStyle）
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: scheme.onSurface,
        ),
        // 卡片标题、设置项
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
        ),
        // 「我想说」正文、消息气泡
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w400,
          height: 1.75,
          color: scheme.onSurface,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          height: 1.6,
          color: scheme.onSurface,
        ),
        // 副信息默认就走唯一那档次级灰，省得每处再 copyWith 一遍
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: scheme.onSurfaceVariant,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        // 分组标题、状态标签
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
