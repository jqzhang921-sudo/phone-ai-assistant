import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_shape.dart';
import '../services/app_providers.dart';
import 'glass_surface.dart';

/// 卡片表面。**自己判断该画实心还是玻璃**，调用方不用管。
///
/// 换成它之后，卡片站点只写「这是一张卡」，玻璃开关、有没有背景图、
/// 背景花不花、强调色是什么，全在这里收口。避免十几处 Container 各自
/// 抄一遍同样的判断——那种散落的条件迟早会有一处漏改。
///
/// 三个条件全满足才画玻璃：
///
/// 1. 用户打开了玻璃开关（`AppSettings.glassSurface`）
/// 2. 真的贴了背景图（`BackgroundProvider.path != null`）
/// 3. 背景图解析成功（拿得到 busyness）
///
/// 少一条就回落到实心卡片。**第 2 条尤其要紧**：没有背景图时底下是一整块
/// `scheme.surface`，糊它等于白付一次 saveLayer 加一次全屏高斯模糊，
/// 换来的画面和实心卡片一模一样。
class AppSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;

  /// 导航条这类浮在滚动内容之上的表面。玻璃会更厚一点，实心会用更重的阴影。
  final bool floating;

  /// 实心模式下的底色。默认 `surfaceContainerLow`（卡片色）。
  final Color? solidColor;

  const AppSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    this.floating = false,
    this.solidColor,
  });

  const AppSurface.card({
    super.key,
    required this.child,
    this.solidColor,
  }) : borderRadius = AppRadius.lgAll,
       floating = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    final bg = context.watch<BackgroundProvider>();
    final settings = context.watch<SettingsProvider>().settings;
    final glassOn = settings?.glassSurface ?? false;

    if (glassOn && bg.path != null) {
      return GlassSurface(
        borderRadius: borderRadius,
        busyness: bg.backgroundBusyness,
        // darkForeground 为 true 表示背景偏亮、字要用深色——那时候玻璃也该是白的。
        lightBackground: bg.darkForeground ?? !dark,
        tint: bg.backgroundAccent,
        floating: floating,
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: solidColor ?? scheme.surfaceContainerLow,
        borderRadius: borderRadius,
        boxShadow:
            floating ? AppShadow.softenFloating(dark) : AppShadow.soften(dark),
      ),
      child: child,
    );
  }
}
