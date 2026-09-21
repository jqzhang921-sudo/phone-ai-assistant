import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/pet_state.dart';
import '../services/stickers.dart';

/// 浮在 App 界面上的那只 Mochi。
///
/// 2026-09-20 Cleo：「悬浮窗小猫可以只在 app 里面出现吗」。可以——而且**只在
/// 自己界面上浮着就不是悬浮窗**：不要 SYSTEM_ALERT_WINDOW 权限、不被 ColorOS
/// 的后台策略管、不额外耗电、也不会挡住别的 App。我原先列的三个缺点全都不存在。
///
/// 挂在 `MaterialApp.builder` 那一层（和开屏同一层），所以它浮在**所有**页面上，
/// 包括从导航栈里推出去的日记、信那些。
///
/// ## 三条规矩
///
/// - **默认不出现**，她在设置里打开才浮着。这是个会一直挡在屏幕上的东西，
///   不该未经同意就出现在她每一页上——「看一眼屏幕」那条提示的教训就是这个。
/// - **拖到哪儿记在哪儿**，下次打开还在原地。
/// - **长按收起**：收起是她自己的动作，所以配一句话告诉她去哪儿再打开；
///   而不是悄悄消失。
class MochiPet extends StatefulWidget {
  const MochiPet({super.key});

  @override
  State<MochiPet> createState() => _MochiPetState();
}

class _MochiPetState extends State<MochiPet>
    with SingleTickerProviderStateMixin {
  /// 画多大。够点得到，又不至于压住半屏内容。
  static const _size = 72.0;

  Offset? _spot;
  int _taps = 0;
  String? _reaction;
  Timer? _reactionTimer;

  /// 待机时轻轻起伏。不是走动——走动会抢注意力，这只是「活着」。
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final at = await PetState.savedSpot();
    if (!mounted) return;
    setState(() => _spot = at);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开了「减少动画」就别起伏。
    if (MediaQuery.disableAnimationsOf(context)) {
      _bob.stop();
    } else if (!_bob.isAnimating) {
      _bob.repeat();
    }
  }

  @override
  void dispose() {
    _reactionTimer?.cancel();
    _bob.dispose();
    super.dispose();
  }

  /// 第一次出现时待在哪儿：右下角，避开悬浮导航条。
  Offset _defaultSpot(Size screen, EdgeInsets safe) =>
      Offset(screen.width - _size - 12, screen.height - safe.bottom - _size - 108);

  void _tapped() {
    _reactionTimer?.cancel();
    setState(() => _reaction = petTapReaction(_taps++));
    _reactionTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _reaction = null);
    });
  }

  Future<void> _hide() async {
    await PetState.setVisible(false);
    if (!mounted) return;
    // 她自己按的，所以说一句去哪儿找回来——但只说 2 秒，不挡着她做事。
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('小猫收起来了。设置 → 那只小猫，可以再放出来'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PetState.visibleNow,
      builder: (context, visible, _) {
        if (!visible) return const SizedBox.shrink();

        final media = MediaQuery.of(context);
        final safe = media.padding;
        final screen = media.size;
        final spot = clampSpot(
          _spot ?? _defaultSpot(screen, safe),
          const Size(_size, _size),
          screen,
          safe: safe,
        );

        return Positioned(
          left: spot.dx,
          top: spot.dy,
          child: ValueListenableBuilder<PetMood>(
            valueListenable: PetState.mood,
            builder: (context, mood, _) {
              final key =
                  _reaction ?? stickerForMood(mood, DateTime.now());
              final asset =
                  stickerOf(key)?.asset ?? 'assets/stickers/mochi_sit_up.png';
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tapped,
                onLongPress: _hide,
                onPanUpdate: (d) {
                  setState(() => _spot = spot + d.delta);
                },
                onPanEnd: (_) {
                  final at = clampSpot(
                    _spot ?? spot,
                    const Size(_size, _size),
                    screen,
                    safe: safe,
                  );
                  setState(() => _spot = at);
                  PetState.saveSpot(at);
                },
                child: AnimatedBuilder(
                  animation: _bob,
                  builder: (context, child) {
                    // 正在做事的时候不起伏：那会儿它该显得专注。
                    final still = mood != PetMood.idle || _reaction != null;
                    final dy =
                        still ? 0.0 : math.sin(_bob.value * 2 * math.pi) * 2.5;
                    return Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    );
                  },
                  child: Image.asset(
                    asset,
                    width: _size,
                    height: _size,
                    // 像素画：插值会把它糊成一团。
                    filterQuality: FilterQuality.none,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
