import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// 垫在列表底下的徽标水印。
///
/// 这是全 App 唯一的材质层，补的就是「全是纯色块、没有任何质感」那一条。
/// 淡到几乎看不见是故意的——要的是「纸上有东西」，不是一个图案；
/// 气泡/卡片留一点透明度压在上面，才有层次。
///
/// 聊天页和信页共用这一份，别各画各的。
///
/// 玻璃模式下的那层模糊**不在这里**——它在 home_shell 里，整页糊一次，
/// 聊天/书架/栖息共用。别在这一层再糊一遍，会叠成两次。
class MarkBackdrop extends StatelessWidget {
  final Widget child;

  /// 徽标宽度。聊天页 230，内页可以小一点。
  final double width;

  const MarkBackdrop({super.key, required this.child, this.width = 230});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Align(
              // 设计稿是 top:46%——比正中略高一点。压在正中会显得往下坠，
              // 因为下面还有输入条，视觉重心本来就偏低。
              alignment: const Alignment(0, -0.08),
              child: Opacity(
                opacity: dark ? 0.06 : 0.045,
                child: Image.asset(
                  'assets/mark-full.png',
                  width: width,
                  // 深色用品牌奶白（背景色那档），不是主文字色——
                  // 它是纸的颜色，不是字的颜色。
                  //
                  // 也跟着 tone 转：它压在整页最底下，一片棕味的水印会把
                  // 上面所有透明表面一起带偏。
                  color: AppTone.of(context).shift(
                    dark ? const Color(0xFFFDF8F1) : AppTheme.brandBrown,
                  ),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
