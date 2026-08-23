import 'package:flutter/material.dart';

import '../config/app_shape.dart';

/// 「正在输入」的三个点。
///
/// 换掉的是 AppBar 底下那条 `LinearProgressIndicator`。两个毛病：
///
/// 1. **说的事情不对。** 进度条是「App 在忙」——系统级的程序状态。
///    而这里真正发生的是「对面在回话」。同一个等待，前者读起来像加载，
///    后者才像有人在那头。
/// 2. **位置不对。** 等回复的人盯着的是消息末尾，不是屏幕最顶端那 2 个像素。
///
/// 现在它作为列表的最后一项出现——回复将来落在哪儿，它就等在哪儿。
///
/// 只在**还没吐出第一个字**时显示（判断在 chat_screen 的 `_showTyping`）。
/// 一旦开始流式输出，回复本身就在那儿了，再挂一个「正在输入」是同一件事
/// 说两遍，而且它就悬在正在生长的那段字下面，很吵。
class TypingIndicator extends StatefulWidget {
  /// 它的名字。空着就只显示三个点——**不要兜底成「AI」或者「助手」**，
  /// 那是给这段关系起名字，chat_screen 里那条原则同样管这儿。
  final String name;

  const TypingIndicator({super.key, this.name = ''});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 三个点错开相位，各自淡进淡出。
  ///
  /// 用连续的三角波而不是「亮/灭」分段跳变：跳变的节奏读起来是转圈的加载图标，
  /// 连续的明暗才像有人在那头敲字。相位差 0.18 是让三个点看得出先后，
  /// 又不至于散成三件事。
  double _opacity(double t, int index) {
    final phase = (t - index * 0.18) % 1.0;
    final wave = (1 - (phase * 2 - 1).abs()); // 0→1→0 的三角波
    return 0.28 + 0.62 * wave;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = widget.name.trim();

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: AppRadius.lgAll,
              boxShadow: AppShadow.soften(theme.brightness == Brightness.dark),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (name.isNotEmpty) ...[
                  Text(
                    name,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                AnimatedBuilder(
                  animation: _controller,
                  builder: (_, __) {
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 3; i++)
                          Padding(
                            padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                            child: Opacity(
                              opacity: _opacity(_controller.value, i),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: scheme.onSurfaceVariant,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
