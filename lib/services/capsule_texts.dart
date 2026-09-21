import 'package:live_capsule/live_capsule.dart';

import 'notify_name.dart';
import 'pet_state.dart';

/// 流体云胶囊里写什么、什么时候收。
///
/// 2026-09-16 Cleo 选了两件事进胶囊：**它在写回复**、**它在看你的屏幕**。
/// 两条路在不同的地方（聊天页 / 后台叫醒），文案和收尾的规矩放一处，
/// 省得两边各写各的、其中一条忘了收。
///
/// ## 规矩
///
/// - **亮了就一定要收**，出错那条路也要收。用 [around] 的话 finally 已经管了；
///   手动 [Capsule.start] 的地方，每个出口都得有 [Capsule.end]。
/// - **不支持就整条路不走**：老系统、她在系统设置里关了实时更新。
///   不退回去发普通常驻通知——那会在通知栏里赖着，比没有更烦。
/// - 胶囊里那几个字越短越好，挖孔旁边就那么点地方。
class Capsule {
  /// 标题用她给它起的备注，和通知栏那条一致（见 [NotifyName]）。
  static Future<String> name() => NotifyName.resolve('Nook');

  static const replyText = '在写回复';
  static const replyShort = '在写';
  static const glanceText = '在看一眼你的屏幕';
  static const glanceShort = '在看';

  /// 亮一个胶囊。返回 false 表示这台机器亮不了，调用方**不用**再去 [end]。
  static Future<bool> start({
    required int id,
    required String text,
    required String short,
  }) async {
    try {
      if (!await LiveCapsule.supported()) return false;
      return await LiveCapsule.show(
        id: id,
        title: await name(),
        text: text,
        short: short,
      );
    } catch (_) {
      // 胶囊亮不出来不影响正在做的事。
      return false;
    }
  }

  static Future<void> end(int id) async {
    try {
      await LiveCapsule.end(id);
    } catch (_) {}
  }

  /// 做 [body] 这件事的时候亮着胶囊，做完（或者出错）一定收。
  static Future<T> around<T>({
    required int id,
    required String text,
    required String short,
    required Future<T> Function() body,
  }) async {
    final on = await start(id: id, text: text, short: short);
    try {
      return await body();
    } finally {
      if (on) await end(id);
    }
  }

  /// 浮在 App 里那只小猫跟着变。
  ///
  /// 搭胶囊的车：下面两段本来就把「正在做这件事」括起来了，小猫不另拉一套
  /// 开始/结束——两套括号迟早有一套忘了收。
  static Future<T> _withMood<T>(PetMood mood, Future<T> Function() body) async {
    PetState.mood.value = mood;
    try {
      return await body();
    } finally {
      PetState.mood.value = PetMood.idle;
    }
  }

  /// 它在写回复：她走开了也看得见写到哪儿了。
  static Future<T> whileReplying<T>(Future<T> Function() body) => around(
    id: LiveCapsule.replyId,
    text: replyText,
    short: replyShort,
    body: () => _withMood(PetMood.typing, body),
  );

  /// 它在看一眼屏幕。**这个尤其该有**：看屏幕这件事本来就答应过「看过一定留痕」，
  /// 胶囊是当场那一份痕迹——正在看的时候她就知道。
  static Future<T> whileGlancing<T>(Future<T> Function() body) => around(
    id: LiveCapsule.glanceId,
    text: glanceText,
    short: glanceShort,
    body: () => _withMood(PetMood.glancing, body),
  );
}
