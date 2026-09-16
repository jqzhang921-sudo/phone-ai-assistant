import 'dart:async';

import 'package:flutter/services.dart';

/// 正在进行的一件事，显示在挖孔那一圈——ColorOS 叫流体云。
///
/// 2026-09-16 Cleo：「要不要看一下这个流体云怎么搞得」。查下来是原生路子：
/// ColorOS 16 的流体云直接显示安卓 16 的「实时更新」通知，不用接 OPPO 的 SDK，
/// 也不用申请白名单。系统那边的硬条件写在 [LiveCapsulePlugin] 的注释里。
///
/// ## 这里的规矩
///
/// - **只用来显示正在进行的事**，事情一结束必须 [end]。胶囊赖着不走比没有更烦。
/// - **不支持就什么都不做**（老系统、她在设置里关了）。不要退回去发普通常驻通知。
/// - **一件事一个 [id]**，再 [show] 一次就是改那一个，不会堆出第二个。
class LiveCapsule {
  static const _channel = MethodChannel('live_capsule');

  /// 它在写回复。
  static const replyId = 101;

  /// 它在看一眼屏幕。
  static const glanceId = 102;

  /// 测试里换掉，省得去碰平台通道。
  static Future<bool> Function(String method, Map<String, dynamic> args) invoke =
      _invoke;

  /// 这台机器能不能亮胶囊。每次都问原生：她随时可能在设置里关掉。
  static Future<bool> supported() => invoke('supported', const {});

  /// 亮一个，或者改已经亮着的那个。
  ///
  /// [title] 必须有，系统的硬条件。[short] 是挖孔那一圈里的几个字，越短越好。
  static Future<bool> show({
    required int id,
    required String title,
    required String text,
    String? short,
  }) => invoke('show', {
    'id': id,
    'title': title,
    'text': text,
    if (short != null) 'short': short,
  });

  /// 事情做完了，收起来。**每条路都要走到这里**，包括出错那条。
  static Future<bool> end(int id) => invoke('end', {'id': id});

  static Future<bool> _invoke(String method, Map<String, dynamic> args) async {
    try {
      // 后台里平台通道要是卡住，没有东西会把它叫醒；胶囊没亮不算事故，
      // 但卡住会拖垮整轮主动说话。见 `ScreenGlance._invoke` 同一处顾虑。
      final ok = await _channel
          .invokeMethod<bool>(method, args)
          .timeout(const Duration(seconds: 3));
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
