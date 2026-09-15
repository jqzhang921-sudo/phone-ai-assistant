import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'nudge_service.dart';
import 'screen_glance.dart';

/// 「看一眼屏幕」断了没有，断了告诉她。
///
/// ## 为什么会断
///
/// 安卓的规矩：无障碍服务绑着的时候，App 进程只要被停掉（强行停止、一键清理、
/// 内存紧张被杀、被设成调试应用），系统就把这个服务记成「崩溃」，**之后不会
/// 自己再接回来**——哪怕 App 重新打开。设置页上显示「无法运行」「此服务出现故障」，
/// 只能她去无障碍里关掉再打开一次。
///
/// 2026-09-15 真机上就是这样断的：开发者选项里「选择调试应用」被点成了 Nook，
/// 系统三次强行停止 App，服务就一直挂着。她问「这个该不会会定期崩溃吧」——
/// 不会自己崩，但被停掉就会断，而她不去设置页根本不知道。所以要主动说。
class GlanceHealth {
  static const _kNotifiedAt = 'glance_broken_notified_at';

  /// 同一件事多久最多提醒一次。后台每十几分钟醒一回，不设间隔就是一晚上几十条。
  static const gap = Duration(hours: 12);

  /// 她允许了、系统设置里也开着，但服务没绑上 = 断了。
  ///
  /// 没允许的、系统里没开的都不算：那是她自己的选择，不是故障。
  static Future<bool> broken() async {
    if (!await ScreenGlance.allowed()) return false;
    final s = await ScreenGlance.status();
    return s.supported && s.enabled && !s.bound;
  }

  /// 纯函数：离上次提醒够不够久。
  static bool shouldNotify(DateTime now, DateTime? last) =>
      last == null || now.difference(last) >= gap;

  /// 测试里换掉，不去碰通知插件。
  @visibleForTesting
  static Future<void> Function(String title, String body) show = _show;

  static const title = '「看一眼屏幕」断开了';
  static const body = '系统把它停掉了。去无障碍里把「让它看一眼屏幕」关掉再打开一次，就能接回来。';

  /// 后台醒来时调：断了就发一条通知，[gap] 之内不重复。返回有没有真的发。
  static Future<bool> notifyIfBroken({DateTime? now}) async {
    try {
      if (!await broken()) return false;
      final at = now ?? DateTime.now();
      final sp = await SharedPreferences.getInstance();
      final lastMs = sp.getInt(_kNotifiedAt);
      final last =
          lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!shouldNotify(at, last)) return false;
      await show(title, body);
      await sp.setInt(_kNotifiedAt, at.millisecondsSinceEpoch);
      return true;
    } catch (e) {
      // 提醒发不出来不能拖垮后台那一轮主动说话。
      debugPrint('[glance] 断开提醒没发出去：$e');
      return false;
    }
  }

  static Future<void> _show(String title, String body) async {
    if (!await NudgeService.ensurePermission()) return;
    await NudgeService.init();
    await FlutterLocalNotificationsPlugin().show(
      'glance_broken'.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'glance',
          '看一眼屏幕',
          channelDescription: '「看一眼屏幕」被系统停掉、需要重新打开时提醒',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }
}
