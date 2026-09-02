import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/letter.dart';
import 'ai_client.dart';
import 'letter_generator.dart';
import 'storage_service.dart';

/// 信从「当场生成」改成「过一会儿再写」。
///
/// ## 为什么原来是当场写
///
/// `habitat_screen` 里那段注释写着：不做后台任务，因为生成要联网、人得在前台，
/// 而且国产 ROM 的后台限制让定时生成不可靠。
///
/// **前半句的前提已经变了**（后台唤醒接上了），后半句仍然成立。所以这里的形状是
/// 「后台是加分项，不是必需品」：到点了谁先醒谁写——后台醒了后台写，
/// 后台被掐了就等她下次进栖息页时补上。
///
/// ## 为什么值得延时
///
/// 当场写的问题不只是「像自动售货机」。更实际的一条：**「我刚写完一封信」
/// 这句话永远说不出口**——信是在她用 App 的时候生成的，那会儿她就在跟它说话，
/// 主动说话的门槛（离上次聊天满三小时）必然挡着；等三小时后能说了，
/// 「刚写完」已经不成立。
///
/// 延时之后，写完那一刻她多半不在，这句话第一次能在真的刚写完的时候说出口。
class LetterSchedule {
  static const _kDueAt = 'letter_due_at';

  /// 排多久之后写。
  ///
  /// 取随机不是为了好玩：固定值过两天就被认出来了（「一进去半小时准来信」），
  /// 那和当场生成一样是台机器，只是慢一点。区间取「她放下手机之后的一段」，
  /// 短到当天还记得起因，长到不像是被那次操作触发的。
  static const _minDelay = Duration(minutes: 25);
  static const _maxDelay = Duration(minutes: 100);

  static final _rand = Random();

  static Future<DateTime?> dueAt() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kDueAt);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> _setDueAt(DateTime? t) async {
    final sp = await SharedPreferences.getInstance();
    if (t == null) {
      await sp.remove(_kDueAt);
    } else {
      await sp.setString(_kDueAt, t.toIso8601String());
    }
  }

  /// 素材够了、也过了冷却，就排一次。已经排着了就不重排。
  ///
  /// 返回排定的时间；条件不满足或已经排过，返回 null。
  static Future<DateTime?> scheduleIfReady() async {
    if (await dueAt() != null) return null; // 已经排着了
    if (!await shouldWriteLetter()) return null;

    final span = _maxDelay.inMinutes - _minDelay.inMinutes;
    final at = DateTime.now().add(
      Duration(minutes: _minDelay.inMinutes + _rand.nextInt(span + 1)),
    );
    await _setDueAt(at);
    return at;
  }

  /// 栖息页那张卡上的一句话。
  ///
  /// 排期是比生成器高一层的东西，所以这句收口在这里，而不是让
  /// `letterTriggerStatus` 反过来 import 排期——那会转成循环依赖。
  ///
  /// 已经排上了就先说这个：条件早就满足了，再说「素材够了，随时可能写一封」
  /// 是句废话，用户想知道的是「那到底写不写」。
  ///
  /// **不报具体几点几分**：那会把它变成一个倒计时，而这件事的分寸恰恰在于
  /// 「它什么时候想写就什么时候写」。
  static Future<String> statusLine() async {
    if (await dueAt() != null) return '它想写一封，还没动笔';
    return letterTriggerStatus();
  }

  /// 到点了就真写。没到点、没排过、或者没配模型，都返回 false。
  ///
  /// 前台后台共用这一个：栖息页进来时调一次，后台唤醒时也调一次。
  /// 谁先到谁写，写完清掉排期，另一边再调就是空跑。
  static Future<bool> writeIfDue({required AiClient aiClient}) async {
    final due = await dueAt();
    if (due == null || DateTime.now().isBefore(due)) return false;

    try {
      final content = await generateLetter(aiClient: aiClient);
      // 无论写没写出东西都记一次尝试并清掉排期。不记的话素材一直堆着，
      // 每次醒来都重新触发，白烧 token。
      await StorageService.setLastLetterAttempt(DateTime.now());
      await _setDueAt(null);
      if (content == null) return false;
      await StorageService.addLetter(
        Letter(
          id: const Uuid().v4(),
          author: LetterAuthor.ai,
          content: content,
        ),
      );
      return true;
    } catch (_) {
      // 网络抽风之类的：**排期往后推，别原地重试**。
      // 留在原地的话，后台每 15 分钟醒来都会再试一次，一直失败一直试。
      await _setDueAt(DateTime.now().add(const Duration(minutes: 30)));
      return false;
    }
  }
}
