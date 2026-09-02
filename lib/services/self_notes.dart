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

TA 说了一件**有下文的事**——去做一件要花时间的事、等一个结果、出门办事——
那件事在 TA 说完的时候还没结束。你要是确实想知道后来怎么样了，
用 follow_up_later 给自己留一张便签，到点系统会把它拿回来给你看。

**等多久由你定**，因为只有你听得出那是件多大的事：做饭是几十分钟，
等一个电话可能两小时，考试可能是明天。别取整凑数，按那件事真实需要的时间估。

留便签是件安静的事：**不用告诉 TA 你会回来问**，那样等于先许一个承诺。
到点了你会重新判断一次，那会儿觉得不合适，不说就是了——所以拿不准可以先留着。

只在**真想知道后来怎么样**的时候留。为了显得关心而留，到点就只能问出一句
空话；而空话比不问更难看。
''';

class SelfNoteStore {
  static const _key = 'self_notes';

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

  /// 返回 false = 已经挂了太多，这次没留下。
  static Future<bool> add(SelfNote note) async {
    final now = DateTime.now();
    // 顺手把过期的清掉，否则一堆早就作废的便签会一直占着名额。
    final live = (await list()).where((n) => !n.isStale(now)).toList();
    if (live.length >= maxPending) return false;
    live.add(note);
    await _save(live);
    return true;
  }

  static Future<void> remove(String id) async {
    final notes = await list();
    await _save(notes.where((n) => n.id != id).toList());
  }

  /// 到点了、还没过期的那些；顺手把过期的从存储里清掉。
  static Future<List<SelfNote>> due(DateTime now) async {
    final all = await list();
    final live = all.where((n) => !n.isStale(now)).toList();
    if (live.length != all.length) await _save(live);
    return live.where((n) => n.isDue(now)).toList();
  }
}
