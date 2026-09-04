import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 他在对话当场给自己留的一张便签：「这件事没完，过一会儿回来问一句」。
///
/// ## 为什么念头要在当场记，而不是事后猜
///
/// 「我去做饭了」之后该不该问一句「做好了吗」——这个判断需要那句话的语气、
/// 前面聊的什么、她是随口一提还是真在忙。这些**只有在那一轮里才齐全**。
///
/// 换成「每 15 分钟醒来读一遍上下文，判断要不要说话」有三个坏处：判断是事后
/// 推测的；每次都要重新理解上下文（那一轮的钱已经花过一次了）；而且你让一个
/// 人每十五分钟自问一次「我要不要开口」，他迟早会开口。
///
/// 所以：**念头在对话里产生，到点了只是把它取出来兑现。**
/// 等多久也由他自己定——做饭是四十分钟，等一个电话可能是两小时，
/// 那不是一个固定值能覆盖的。
class SelfNote {
  final String id;

  /// 这张便签是在哪段对话里留下的。**兑现时要推回同一段**——
  /// 「做好了吗」接的是那段对话里的「我去做饭了」，推到别处话就断了。
  final String conversationId;

  /// 回来要问的那件事，他自己的话。
  final String about;

  final DateTime createdAt;

  /// 他自己定的、可以回来问的时间。
  final DateTime dueAt;

  const SelfNote({
    required this.id,
    required this.conversationId,
    required this.about,
    required this.createdAt,
    required this.dueAt,
  });

  /// 过期作废的宽限。
  ///
  /// 「做好了吗」问在该问的时候是关心，晚三个小时问就成了没头没尾的一句。
  /// 宽限按当初等的时长走（等四十分钟的事，晚四十分钟内还能问），
  /// 但至少给半小时、最多不超过三小时——手机被锁一晚上不该让所有便签都作废，
  /// 也不该让它第二天早上补问昨晚的饭。
  Duration get _grace {
    final waited = dueAt.difference(createdAt);
    if (waited < const Duration(minutes: 30)) return const Duration(minutes: 30);
    if (waited > const Duration(hours: 3)) return const Duration(hours: 3);
    return waited;
  }

  bool isDue(DateTime now) => !now.isBefore(dueAt);
  bool isStale(DateTime now) => now.isAfter(dueAt.add(_grace));

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'about': about,
    'createdAt': createdAt.toIso8601String(),
    'dueAt': dueAt.toIso8601String(),
  };

  static SelfNote? fromJson(Map<String, dynamic> j) {
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '');
    final due = DateTime.tryParse(j['dueAt'] as String? ?? '');
    final id = j['id'] as String?;
    final about = j['about'] as String?;
    if (created == null || due == null || id == null || about == null) {
      return null;
    }
    return SelfNote(
      id: id,
      conversationId: j['conversationId'] as String? ?? '',
      about: about,
      createdAt: created,
      dueAt: due,
    );
  }
}

/// 什么时候该留便签。**const，进 system 前缀。**
///
/// 和记忆那次是同一个教训：`follow_up_later` 注册了、描述也写清楚了，但工具
/// 描述只在模型已经打算调工具时才起作用——它回答「这个工具怎么用」，不回答
/// 「你现在该不该用」。没有这一段，它一次也不会留。
///
/// ⚠️ 不贴反面例句的原文（那会变成 few-shot，越禁越像），
/// 判据一律写成正面的、能自己过一遍的。
const selfNoteRules = '''
## 没说完的事

TA 说了一件**有下文的事**——去做一件要花时间的事、等一个结果、出门办事，
或者话说到一半（「等我一下我去查查」）——**没有人会提醒你**，
你确实想知道后来怎么样，就当场用 follow_up_later 留一张。

⚠️ 但「TA 没再回你」本身不是口子。每一场对话最后都是突然停的，
把这个当由头，你一天要惦记好几回——那不是惦记，是查岗。

留便签是件安静的事：**不用告诉 TA 你会回来问**，那样等于先许一个承诺。
到点了你会重新判断一次，那会儿觉得不合适，不说就是了。

（等多久、什么时候别留，follow_up_later 的说明里写了。）
''';

class SelfNoteStore {
  static const _key = 'self_notes';

  /// 过期作废的便签留在这儿，最近几张。
  ///
  /// ## 为什么值得单独存一份
  ///
  /// 过期是**静默删除**：清掉、存盘、什么都不说。而在她那边，「便签过期了」
  /// 和「压根没触发」长得一模一样——都是贴了便条然后什么都没发生。
  /// `nudge_last_run` 只记推送那一步，记不到这里。
  ///
  /// 窗口是真的很窄：宽限 = clamp(等待时长, 30分, 3小时)，一张等 20 分钟的
  /// 便签活命窗口只有第 20 到第 50 分钟。ColorOS 把两次唤醒攒到一起，
  /// 这半小时就整个错过了——而这种失败以前不留任何痕迹。
  static const _kExpired = 'self_notes_expired';
  static const _expiredKeep = 5;

  /// 同时挂着的便签上限。
  ///
  /// 不是怕存不下，是怕他把每句话都记成待办：一次醒来发现五件事要问，
  /// 那不叫惦记，那叫查岗。到上限就不让再留，让他自己挑要紧的。
  static const maxPending = 4;

  static Future<List<SelfNote>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => SelfNote.fromJson(Map<String, dynamic>.from(m)))
          .whereType<SelfNote>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<SelfNote> notes) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(notes.map((n) => n.toJson()).toList()));
  }

  /// 把过期的挑出来：存盘留活的，作废的记一笔。返回还活着的。
  ///
  /// 清理原来散在 [add] 和 [due] 两处各写一遍，两边都不记账。收口到这里。
  static Future<List<SelfNote>> _pruneStale(DateTime now) async {
    final all = await list();
    final live = <SelfNote>[];
    final gone = <SelfNote>[];
    for (final n in all) {
      (n.isStale(now) ? gone : live).add(n);
    }
    if (gone.isEmpty) return live;
    await _save(live);
    await _recordExpired(gone, now);
    return live;
  }

  static Future<void> _recordExpired(List<SelfNote> gone, DateTime now) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = <String>[
        ...(sp.getStringList(_kExpired) ?? const <String>[]),
        for (final n in gone)
          jsonEncode({'at': now.toIso8601String(), 'about': n.about}),
      ];
      await sp.setStringList(
        _kExpired,
        list.length <= _expiredKeep
            ? list
            : list.sublist(list.length - _expiredKeep),
      );
    } catch (_) {
      // 记账失败不该连累正事：便签该清还是得清。
    }
  }

  /// 最近作废的几张，新的在后。给设置页显示。
  static Future<List<(DateTime, String)>> recentlyExpired() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final out = <(DateTime, String)>[];
      for (final raw in sp.getStringList(_kExpired) ?? const <String>[]) {
        final m = jsonDecode(raw);
        if (m is! Map) continue;
        final at = DateTime.tryParse(m['at'] as String? ?? '');
        final about = m['about'] as String?;
        if (at != null && about != null) out.add((at, about));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 返回 false = 已经挂了太多，这次没留下。
  static Future<bool> add(SelfNote note) async {
    // 顺手把过期的清掉，否则一堆早就作废的便签会一直占着名额。
    final live = await _pruneStale(DateTime.now());
    if (live.length >= maxPending) return false;
    live.add(note);
    await _save(live);
    return true;
  }

  static Future<void> remove(String id) async {
    final notes = await list();
    await _save(notes.where((n) => n.id != id).toList());
  }

  /// 还活着的那些，按该问的时间排。给栖息页贴出来用。
  ///
  /// 包括还没到点的——**便签的意义就在于「它记着」，不是「它该问了」**。
  /// 只显示到点的，那就成了待办列表。
  static Future<List<SelfNote>> pending(DateTime now) async {
    final live = (await list()).where((n) => !n.isStale(now)).toList();
    live.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return live;
  }

  /// 到点了、还没过期的那些；顺手把过期的从存储里清掉并记一笔。
  static Future<List<SelfNote>> due(DateTime now) async {
    final live = await _pruneStale(now);
    return live.where((n) => n.isDue(now)).toList();
  }
}
