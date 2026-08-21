import 'package:flutter/material.dart';
import 'app_shape.dart';

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

  /// 页面底色（奶白）。聊天背景预设 `light` 也取这个值——
  /// 那层预设是整屏铺在主题上面的，写死颜色会把 ColorScheme.surface 盖掉。
  static const Color surfaceLight = Color(0xFFFDF8F1);

  /// 页面底色（暖黑，不用纯黑）。聊天背景预设 `dark` 同上。
  static const Color surfaceDark = Color(0xFF171310);

  static ThemeData get light => _build(Brightness.light, true);
  static ThemeData get dark => _build(Brightness.dark, true);

  /// [titleSerif] true 时 AppBar 标题用衬线体（Noto Serif SC），false 用默认黑体
  static ThemeData lightWith({required bool titleSerif}) =>
      _build(Brightness.light, titleSerif);
  static ThemeData darkWith({required bool titleSerif}) =>
      _build(Brightness.dark, titleSerif);

  static ColorScheme _scheme(Brightness brightness) {
    final light = brightness == Brightness.light;
    return ColorScheme(
      brightness: brightness,
      // 全 App 唯一的强调色：徽标的温暖棕。深色下必须换成浅棕，
      // 否则整块主色会沉进暗底里看不见。
      primary: light ? const Color(0xFF8B5E34) : const Color(0xFFD9B48F),
      onPrimary: light ? Colors.white : const Color(0xFF2A211A),
      // 选中态的淡底。深色用 18% alpha 的浅棕，不用实色——
      // 实色主色做选中底太重，会和顶部的棕色元素抢。
      primaryContainer:
          light ? const Color(0xFFEFE3D4) : const Color(0x2ED9B48F),
      onPrimaryContainer:
          light ? const Color(0xFF6F4A28) : const Color(0xFFEBD9C4),
      // 徽标的辅助浅棕。它是「装饰用的浅色块」，不是前景色——
      // 拿它当图标或文字色放在奶白底上只有 1.5:1，别这么用。
      secondary: const Color(0xFFD9B48F),
      onSecondary: light ? const Color(0xFF3B2A17) : const Color(0xFF2A211A),
      secondaryContainer:
          light ? const Color(0xFFF3E7D8) : const Color(0xFF3A2F26),
      onSecondaryContainer:
          light ? const Color(0xFF5A4429) : const Color(0xFFEBD9C4),
      // 第三档不再是「更浅一点的灰」，直接对齐唯一那档次级灰
      tertiary: light ? const Color(0xFF787168) : const Color(0xFF948A80),
      onTertiary: light ? Colors.white : const Color(0xFF171310),
      tertiaryContainer:
          light ? const Color(0xFFEFEDE9) : const Color(0xFF2B2521),
      onTertiaryContainer:
          light ? const Color(0xFF3A342E) : const Color(0xFFE3D9CE),
      error: light ? const Color(0xFFBA1A1A) : const Color(0xFFFFB4AB),
      onError: light ? Colors.white : const Color(0xFF690005),
      errorContainer: light ? const Color(0xFFFFDAD6) : const Color(0xFF93000A),
      onErrorContainer:
          light ? const Color(0xFF410002) : const Color(0xFFFFDAD6),
      // 底色奶白、卡片纯白：两者只差一点亮度，所以层次全压在阴影上。
      // 深色反过来——不画阴影，靠 #171310 → #251F1A 这一档明度差。
      surface: light ? surfaceLight : surfaceDark,
      onSurface: light ? const Color(0xFF1A1512) : const Color(0xFFF2EAE0),
      surfaceContainerLowest:
          light ? const Color(0xFFFFFFFF) : const Color(0xFF110E0B),
      surfaceContainerLow:
          light ? const Color(0xFFFFFFFF) : const Color(0xFF251F1A),
      surfaceContainer:
          light ? const Color(0xFFFFFFFF) : const Color(0xFF251F1A),
      surfaceContainerHigh:
          light ? const Color(0xFFF5F0E8) : const Color(0xFF2E2721),
      // 输入框底
      surfaceContainerHighest:
          light ? const Color(0xFFEFEDE9) : const Color(0xFF383029),
      // 唯一的次级灰：副标题、meta、计数、导航标签、时间戳全走这一个。
      // 浅色约 4.6:1，深色约 4.7:1。
      onSurfaceVariant:
          light ? const Color(0xFF787168) : const Color(0xFF948A80),
      outline: light ? const Color(0xFF8C8378) : const Color(0xFF8A8079),
      // 只用于组内分隔线（浅 5% / 深 7%）。它不再是描边色——
      // 谁拿它 Border.all 都会得到一条几乎看不见的线，这是故意的。
      outlineVariant: light ? const Color(0x0D1A1512) : const Color(0x12F2EAE0),
      shadow: light ? const Color(0x261A1512) : Colors.black,
      scrim: light ? const Color(0x571A1512) : const Color(0x8C000000),
      inverseSurface: light ? const Color(0xFF302823) : const Color(0xFFF2EAE0),
      onInverseSurface:
          light ? const Color(0xFFF7F1E9) : const Color(0xFF171310),
      inversePrimary: light ? const Color(0xFFD9B48F) : const Color(0xFF8B5E34),
    );
  }

  static ThemeData _build(Brightness brightness, bool titleSerif) {
    final scheme = _scheme(brightness);
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);

    return base.copyWith(
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
