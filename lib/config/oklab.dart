/// OKLab / OKLCH —— 感知均匀的色彩空间。整套配色的颜色运算都走它。
///
/// ## 为什么不用 HSL/HSV
///
/// 它们的「饱和度」不是感知量。同一个数字在不同亮度、不同色相上意思完全不同，
/// 这件事让我们栽过两次：
///
/// 1. **接近黑的像素上，HSV 饱和度是噪声放大器。** `s = (max - min) / max`，
///    分母趋近 0 时它剧烈抖动：`RGB(10, 8, 12)` 肉眼就是黑，算出来
///    `s = 0.33`、色相 270°（蓝紫）。`BackgroundProvider._analyze` 拿它当
///    「这个像素对图片色相有多少发言权」的权重，于是 Cleo 那张「黑底粉兔子」
///    壁纸里八成面积的黑底噪点把票全投给了蓝紫，粉色一票没投上——整个主题
///    变成蓝紫，压在粉兔子上。合成同结构的图复现过：HSV 加权得 265°，
///    OKLab 彩度加权得 325°（粉，正确）。
///
/// 2. **同一个饱和度数值在不同色相上不是同一种「花」。** `#D9B48F`（浅棕）
///    的 HSL 饱和度是 0.49，看着是柔的；把色相转到绿、饱和度照抄 0.49，
///    出来是 `#9AC85E` 一块刺眼的草绿。绿是最亮的色相，要凑到和浅棕一样的
///    亮度就得给到很高的彩度。
///
/// OKLab 的 chroma 在这两处都是对的：接近黑时自然趋于 0，各色相之间可比。
///
/// 公式出自 Björn Ottosson 的 OKLab。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

double _linear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _gamma(double c) =>
    c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

/// 拆成明度 / 彩度 / 色相（度）。彩度对「这个颜色有多花」是可比的量，
/// 所以近黑、近白、纯灰都会自然落在 0 附近。
({double l, double c, double h}) toOklch(Color color) {
  final r = _linear(color.r);
  final g = _linear(color.g);
  final b = _linear(color.b);

  final lms0 = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  final lms1 = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  final lms2 = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

  final l_ = _cbrt(lms0);
  final m_ = _cbrt(lms1);
  final s_ = _cbrt(lms2);

  final lightness = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
  final a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
  final bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

  return (
    l: lightness,
    c: math.sqrt(a * a + bb * bb),
    h: (math.atan2(bb, a) * 180 / math.pi + 360) % 360,
  );
}

/// 反过来。超出 sRGB 色域的通道直接夹住——本项目的调色板彩度都不高
/// （最花的 `#8B5E34` 也只到 0.09），转到任何色相都还在色域内，
/// 夹只是兜底。
Color fromOklch(double l, double c, double h, {double alpha = 1}) {
  final rad = h * math.pi / 180;
  final a = c * math.cos(rad);
  final bb = c * math.sin(rad);

  final l_ = l + 0.3963377774 * a + 0.2158037573 * bb;
  final m_ = l - 0.1055613458 * a - 0.0638541728 * bb;
  final s_ = l - 0.0894841775 * a - 1.2914855480 * bb;

  final lms0 = l_ * l_ * l_;
  final lms1 = m_ * m_ * m_;
  final lms2 = s_ * s_ * s_;

  final r = 4.0767416621 * lms0 - 3.3077115913 * lms1 + 0.2309699292 * lms2;
  final g = -1.2684380046 * lms0 + 2.6097574011 * lms1 - 0.3413193965 * lms2;
  final b = -0.0041960863 * lms0 - 0.7034186147 * lms1 + 1.7076147010 * lms2;

  return Color.from(
    alpha: alpha,
    red: _gamma(r).clamp(0.0, 1.0),
    green: _gamma(g).clamp(0.0, 1.0),
    blue: _gamma(b).clamp(0.0, 1.0),
  );
}

double _cbrt(double x) => x <= 0 ? 0 : math.pow(x, 1 / 3).toDouble();

/// 一个像素在「这张图整体是什么色相」这件事上该有多少发言权。
///
/// **彩度 × 明度**，两个因子缺一不可：
///
/// - 彩度：灰的像素对色相没有意见。
/// - 明度：暗处的颜色对「这张图什么色」的贡献本来就小。只用彩度的话，
///   一整片系统性偏冷的黑还是能攒够票——实测合成图（78% 冷调黑 + 22% 粉）
///   只用彩度得 321°，黑再深再冷就一路漂到 307°；乘上明度稳定在 344–350°
///   （粉，正确）。对正常的亮图两者结果几乎一样。
///
/// 作为对照，原来用的 HSV 饱和度在同一张图上得 260°——蓝紫。
double hueWeight(Color color) {
  final lch = toOklch(color);
  return lch.c * lch.l;
}
