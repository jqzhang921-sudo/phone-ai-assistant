import 'package:flutter/widgets.dart';

/// 全 App 统一的圆角取值。
///
/// 收敛之前散落着 12 种不同的圆角（2/4/8/10/12/14/16/18/20/22/24/29）。
/// 单看每处都还行，放在一起眼睛能察觉到「没有系统」，却指不出是哪里不对——
/// 这类不一致正是界面显得粗糙的主要来源。
///
/// 现在按「元素多大、承载什么」分五档。新界面从这里取值，不要再写字面量。
class AppRadius {
  const AppRadius._();

  /// 徽章、标签、缩略图、嵌在别的卡片里的小卡
  static const double sm = 8;

  /// 消息气泡、按钮、表单输入框
  static const double md = 20;

  /// 卡片、分组容器、对话框、底部弹层
  static const double lg = 24;

  /// 页面上最大的那一张主卡（主页「我想说」、栖息统计卡）
  static const double xl = 28;

  /// 全圆：底部导航项、聊天输入条、拖动条、圆形按钮
  ///
  /// 取一个远大于控件尺寸的值，Flutter 会自动收敛到「半个高度」，
  /// 因此控件高度变化时不需要跟着改这里。
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// 全 App 统一的柔光阴影。
///
/// 卡片和背景之间只差 2% 亮度、又没有阴影时，所有内容会趴在同一个平面上——
/// 这是「不通透、很单薄」的直接来源。层次交给阴影，不要再靠描边去分割。
///
/// 不用 Material 的 `elevation`：它算出来的阴影偏灰偏冷，压在奶白底
/// (`#FDF8F1`) 上会脏。这里自己画，颜色取主文字色 `#1A1512` 的低透明度。
///
/// 每档都是两层：一层贴边的实影定出轮廓，一层大范围的散影撑出高度。
/// **负 `spreadRadius` 是柔光的关键**——阴影先往内收再大范围扩散，
/// 才不会在元素周围糊出一圈灰边。
///
/// 深色模式一律不画阴影：暗底上的黑影看不见，层次改用
/// `#171310` → `#251F1A` 的明度差。用 [soften] 拿值，别自己判断。
class AppShadow {
  const AppShadow._();

  /// 卡片、分组容器
  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x0A1A1512), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x241A1512),
      blurRadius: 34,
      offset: Offset(0, 14),
      spreadRadius: -14,
    ),
  ];

  /// 悬浮胶囊导航、输入条——比卡片再浮一层
  static const List<BoxShadow> floating = [
    BoxShadow(color: Color(0x0D1A1512), blurRadius: 6, offset: Offset(0, 2)),
    BoxShadow(
      color: Color(0x331A1512),
      blurRadius: 28,
      offset: Offset(0, 12),
      spreadRadius: -14,
    ),
  ];

  /// 书籍封面：更沉，压得住深色封面
  static const List<BoxShadow> cover = [
    BoxShadow(color: Color(0x0F1A1512), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(
      color: Color(0x731A1512),
      blurRadius: 28,
      offset: Offset(0, 12),
      spreadRadius: -14,
    ),
  ];

  /// 深色模式返回空列表。卡片一律用这个取值，不要直接写 [soft]。
  static List<BoxShadow> soften(bool dark) => dark ? const [] : soft;

  /// [floating] 的深色版本
  static List<BoxShadow> softenFloating(bool dark) =>
      dark ? const [] : floating;

  /// [cover] 的深色版本
  static List<BoxShadow> softenCover(bool dark) => dark ? const [] : cover;
}
