import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notify_name.dart';
import 'nudge_service.dart';

/// 她发完消息就走开了，回复在后面写完：弹一条通知叫她回来看。
///
/// 2026-09-15 Cleo：「他正在回复的时候，我返回，回复就被打断了，可不可以是
/// 我可以返回，它恢复好了直接弹通知」。打断的原因在 chat_screen 的
/// `_continueChat`：回首页会把 `_conversation` 换成一段空的，还在跑的那一轮
/// 就写进了空对话里。那边修好之后，写完的回复要有人叫她——就是这里。
///
/// 和主动说话的通知分开一个频道：那边是「它自己想说」，默认重要度，
/// 这边是「你问的它答完了」，她在等，所以要能弹出来。
class ReplyNotifier {
  static const _channelId = 'reply';
  static const _channelName = '它回你了';

  /// 该不该弹。纯函数。
  ///
  /// 人就在这段对话上、App 在前台：回复就在眼前，弹通知是噪音。
  /// 回了首页、切去了别的对话、或者 App 退到后台：弹。
  static bool shouldNotify({
    required bool onThatConversation,
    required AppLifecycleState? lifecycle,
  }) => !onThatConversation || lifecycle != AppLifecycleState.resumed;

  /// 通知里那一行。太长的截掉：通知栏展开也就十几行。
  static String preview(String text, {int max = 200}) {
    final t = text.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  static Future<void> show({
    required String conversationId,
    required String text,
  }) async {
    try {
      if (!await NudgeService.ensurePermission()) return;
      await NudgeService.init();

      // 标题用她自己给它起的备注，见 [NotifyName]。
      final title = await NotifyName.resolve('它回你了');
      // 「通知里不显示内容」是主动说话设置页里那个开关，管的是锁屏上别人
      // 看不看得见——那个顾虑对回复一样成立，不另设一个。
      final hide = (await NudgeService.loadPrefs()).hideContent;

      await FlutterLocalNotificationsPlugin().show(
        // 按对话分 id：同一段里连着回的，后一条顶掉前一条，不堆一串。
        conversationId.hashCode,
        title,
        hide ? '回了你一条消息' : preview(text),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '你走开的时候写完的回复',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: BigTextStyleInformation(''),
          ),
        ),
      );
    } catch (e) {
      // 通知弹不出来不影响回复本身：话已经存进对话里了。
      debugPrint('[reply] 通知没弹出来：$e');
    }
  }
}
