import 'package:flutter/widgets.dart';

/// 全 App 统一的圆角取值。
///
/// 收敛之前散落着 12 种不同的圆角（2/4/8/10/12/14/16/18/20/22/24/29）。
/// 单看每处都还行，放在一起眼睛能察觉到「没有系统」，却指不出是哪里不对——
/// 这类不一致正是界面显得粗糙的主要来源。
///
/// 现在按「元素多大、承载什么」分四档。新界面从这里取值，不要再写字面量。
class AppRadius {
  const AppRadius._();

  /// 徽章、标签、缩略图、嵌在别的卡片里的小卡
  static const double sm = 8;

  /// 卡片、消息气泡、按钮、表单输入框
  static const double md = 16;

  /// 大面积容器：对话框、底部弹层
  static const double lg = 24;

  /// 全圆：底部导航项、聊天输入条、拖动条、圆形按钮
  ///
  /// 取一个远大于控件尺寸的值，Flutter 会自动收敛到「半个高度」，
  /// 因此控件高度变化时不需要跟着改这里。
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}
