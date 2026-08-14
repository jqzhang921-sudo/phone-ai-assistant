import 'package:flutter/material.dart';
import 'app_shape.dart';

/// 黑白灰主题：以中性灰阶为主，深浅色两套。
class AppTheme {
  AppTheme._();

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
      // 全 App 唯一的强调色：赤陶。
      // primary 驱动发送键、FAB、填充按钮、开关、聚焦态——出现频率低，
      // 所以才有强调的意义。其余一律走中性灰阶，不要再引入第二个彩色。
      primary: light ? const Color(0xFFB0552F) : const Color(0xFFE39775),
      onPrimary: light ? Colors.white : const Color(0xFF4A1F0E),
      // primaryContainer 是用户气泡的底色，压得很淡，避免整屏发红
      primaryContainer:
          light ? const Color(0xFFF4E7DF) : const Color(0xFF7A3A1F),
      onPrimaryContainer:
          light ? const Color(0xFF4A1F0E) : const Color(0xFFFFDBCB),
      secondary: light ? const Color(0xFF616161) : const Color(0xFFBDBDBD),
      onSecondary: light ? Colors.white : const Color(0xFF1F1F1F),
      secondaryContainer:
          light ? const Color(0xFFEDEDED) : const Color(0xFF383838),
      onSecondaryContainer:
          light ? const Color(0xFF212121) : const Color(0xFFE0E0E0),
      tertiary: light ? const Color(0xFF757575) : const Color(0xFFA8A8A8),
      onTertiary: light ? Colors.white : const Color(0xFF1F1F1F),
      tertiaryContainer:
          light ? const Color(0xFFF0F0F0) : const Color(0xFF303030),
      onTertiaryContainer:
          light ? const Color(0xFF212121) : const Color(0xFFD0D0D0),
      error: light ? const Color(0xFFBA1A1A) : const Color(0xFFFFB4AB),
      onError: Colors.white,
      errorContainer: light ? const Color(0xFFFFDAD6) : const Color(0xFF93000A),
      onErrorContainer:
          light ? const Color(0xFF410002) : const Color(0xFFFFDAD6),
      // 中性色只做「极轻微」的暖化：红蓝差控制在 3~6，肉眼几乎看不出偏色，
      // 但和暖调背景放在一起不会显得发灰发冷。刻意不做得更黄——
      // 满屏的黄会刺眼，这是背景预设已经踩过的坑。
      // 背景比卡片明显深一档（暖灰而不是近乎纯白），让卡片能"浮"出来，
      // 不是像之前那样跟背景糊在一起分不清层次。
      surface: light ? const Color(0xFFEDEBE6) : const Color(0xFF161514),
      onSurface: light ? const Color(0xFF1A1917) : const Color(0xFFECEBE8),
      surfaceContainerLowest:
          light ? const Color(0xFFFFFFFF) : const Color(0xFF100F0E),
      surfaceContainerLow:
          light ? const Color(0xFFF3F2EF) : const Color(0xFF1C1B1A),
      surfaceContainer:
          light ? const Color(0xFFEEEDEA) : const Color(0xFF211F1E),
      surfaceContainerHigh:
          light ? const Color(0xFFE8E7E3) : const Color(0xFF282625),
      surfaceContainerHighest:
          light ? const Color(0xFFE2E1DD) : const Color(0xFF302E2C),
      onSurfaceVariant:
          light ? const Color(0xFF57544F) : const Color(0xFFA29F9A),
      outline: light ? const Color(0xFF8C8983) : const Color(0xFF8A8783),
      outlineVariant: light ? const Color(0xFFD9D6D0) : const Color(0xFF3E3C3A),
      shadow: Colors.black26,
      scrim: Colors.black38,
      inverseSurface: light ? const Color(0xFF2B2A27) : const Color(0xFFECEBE8),
      onInverseSurface:
          light ? const Color(0xFFF2F1EE) : const Color(0xFF161514),
      inversePrimary: light ? const Color(0xFFCFCFCF) : const Color(0xFF333333),
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
        titleTextStyle: TextStyle(
          fontFamily: titleSerif ? 'NotoSerifSC' : null,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
        ),
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      textTheme: base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          color: scheme.onSurface,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
