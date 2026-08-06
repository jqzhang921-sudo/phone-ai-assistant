import 'package:flutter/material.dart';

/// 黑白灰主题：以中性灰阶为主，深浅色两套。
class AppTheme {
  AppTheme._();

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ColorScheme _scheme(Brightness brightness) {
    final light = brightness == Brightness.light;
    return ColorScheme(
      brightness: brightness,
      primary: light ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
      onPrimary: light ? Colors.white : const Color(0xFF1A1A1A),
      primaryContainer:
          light ? const Color(0xFFE6E6E6) : const Color(0xFF2E2E2E),
      onPrimaryContainer:
          light ? const Color(0xFF1A1A1A) : const Color(0xFFE0E0E0),
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
      surface: light ? const Color(0xFFFAFAFA) : const Color(0xFF141414),
      onSurface: light ? const Color(0xFF171717) : const Color(0xFFECECEC),
      surfaceContainerLowest:
          light ? const Color(0xFFFFFFFF) : const Color(0xFF0E0E0E),
      surfaceContainerLow:
          light ? const Color(0xFFF4F4F4) : const Color(0xFF1A1A1A),
      surfaceContainer:
          light ? const Color(0xFFEFEFEF) : const Color(0xFF1F1F1F),
      surfaceContainerHigh:
          light ? const Color(0xFFE9E9E9) : const Color(0xFF262626),
      surfaceContainerHighest:
          light ? const Color(0xFFE2E2E2) : const Color(0xFF2E2E2E),
      onSurfaceVariant:
          light ? const Color(0xFF555555) : const Color(0xFFA0A0A0),
      outline: light ? const Color(0xFF8C8C8C) : const Color(0xFF8A8A8A),
      outlineVariant: light ? const Color(0xFFD9D9D9) : const Color(0xFF3D3D3D),
      shadow: Colors.black26,
      scrim: Colors.black38,
      inverseSurface: light ? const Color(0xFF2B2B2B) : const Color(0xFFECECEC),
      onInverseSurface:
          light ? const Color(0xFFF2F2F2) : const Color(0xFF141414),
      inversePrimary: light ? const Color(0xFFCFCFCF) : const Color(0xFF333333),
    );
  }

  static ThemeData _build(Brightness brightness) {
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
          borderRadius: BorderRadius.circular(16),
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
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
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
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
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
