import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 用户自己要做的小事，和它的便签贴在同一块板上。
///
/// ## ⚠️ 和便签是两套生命周期，别共用
///
/// 看着都是纸条，规矩是相反的：
///
/// | | 它的便签 | 你的小事 |
/// |---|---|---|
/// | 谁来了结 | 到点它自己判断，说了就撕 | 你做完，你来勾 |
/// | 过期 | **自动作废**（问晚了就没意义） | **绝不自动消失** |
/// | 你能做什么 | 只能撕掉 | 勾完成、随时加 |
///
/// 「自动消失」对便签是对的（「饭做好了吗」过点就不值钱），对小事是灾难——
/// 那不叫过期，那叫丢东西。所以这里**没有任何 stale 逻辑**，一条小事只会因为
/// 你勾了才离开板面。
///
/// ## 勾掉不是删掉
///
/// 勾了只是记一个 [doneAt]，板面不再显示，但东西还在磁盘上留一周。
/// 误触一下就永久丢一件事，代价和收益完全不成比例。
class SmallThing {
  final String id;
  final String text;
  final DateTime createdAt;

  /// 可选的截止时间。不填就是一张纯纸条。
  final DateTime? dueAt;

  /// 勾掉的时间。null = 还没做。
  final DateTime? doneAt;

  const SmallThing({
    required this.id,
    required this.text,
    required this.createdAt,
    this.dueAt,
    this.doneAt,
  });

  bool get isDone => doneAt != null;

  SmallThing copyWith({DateTime? doneAt, bool clearDone = false}) => SmallThing(
    id: id,
    text: text,
    createdAt: createdAt,
    dueAt: dueAt,
    doneAt: clearDone ? null : (doneAt ?? this.doneAt),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    if (dueAt != null) 'dueAt': dueAt!.toIso8601String(),
    if (doneAt != null) 'doneAt': doneAt!.toIso8601String(),
  };

  static SmallThing? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final text = j['text'] as String?;
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '');
    if (id == null || text == null || created == null) return null;
    return SmallThing(
      id: id,
      text: text,
      createdAt: created,
      dueAt: DateTime.tryParse(j['dueAt'] as String? ?? ''),
      doneAt: DateTime.tryParse(j['doneAt'] as String? ?? ''),
    );
  }
}

class SmallThingStore {
  static const _key = 'small_things';

  /// 勾掉之后还留多久。留着是给误触留退路，不是给你回顾用的——
  /// 板面上看不到它们，也没有「已完成」列表。
  static const _keepDone = Duration(days: 7);

  static Future<List<SmallThing>> _all() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => SmallThing.fromJson(Map<String, dynamic>.from(m)))
          .whereType<SmallThing>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<SmallThing> items) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }

  /// 板面上该显示的：没勾的，有截止的排前面（按截止时间），其余按添加顺序。
  static Future<List<SmallThing>> pending() async {
    final now = DateTime.now();
    // 顺手清掉勾了很久的。**只清勾过的**——没勾的永远不动。
    final all = await _all();
    final keep =
        all
            .where(
              (e) =>
                  e.doneAt == null || now.difference(e.doneAt!) < _keepDone,
            )
            .toList();
    if (keep.length != all.length) await _save(keep);

    final live = keep.where((e) => !e.isDone).toList();
    live.sort((a, b) {
      if ((a.dueAt == null) != (b.dueAt == null)) return a.dueAt == null ? 1 : -1;
      if (a.dueAt != null && b.dueAt != null) {
        return a.dueAt!.compareTo(b.dueAt!);
      }
      return a.createdAt.compareTo(b.createdAt);
    });
    return live;
  }

  static Future<void> add(SmallThing item) async {
    await _save([...await _all(), item]);
  }

  /// 勾掉。**不删**，见类注释。
  static Future<void> markDone(String id) async {
    final all = await _all();
    await _save([
      for (final e in all)
        if (e.id == id) e.copyWith(doneAt: DateTime.now()) else e,
    ]);
  }

  /// 撤销勾选。给「手滑点了」用。
  static Future<void> undone(String id) async {
    final all = await _all();
    await _save([
      for (final e in all)
        if (e.id == id) e.copyWith(clearDone: true) else e,
    ]);
  }

  /// 真的不要了。长按撕掉走这条。
  static Future<void> remove(String id) async {
    final all = await _all();
    await _save(all.where((e) => e.id != id).toList());
  }
}

/// 什么时候该替她记一件小事。**const，进 system 前缀。**
///
/// 和记忆、便签是同一个教训：工具注册了不等于它会用，工具描述只回答「怎么用」。
///
/// ⚠️ 这一段和 `selfNoteRules` 最容易被混起来，所以判据写成一句对照：
/// **便签是它自己要回来问的事，小事是她自己要做的事。**
const smallThingRules = '''
## 帮她记小事

TA 提到一件**自己要做、但现在没做**的事——交个费、拿个快递、买点什么、
某天要办的事——用 add_small_thing 贴到板上。TA 不用切界面，随口说了就记下了。

和便签分清楚：**便签是你要回来问的，小事是 TA 要去做的。**
「我去做饭了」是便签（你想知道后来怎么样）；「周五得交房租」是小事
（她要做的事，你只是替她记着）。

记完说一句就行，别复述一遍内容。TA 说完自己知道说了什么。

⚠️ **贴上去之后就别再提了。** 那是她的板子，不是你的待办清单。
她什么时候做、做不做，都不用你跟进——**帮她记着**和**盯着她做**是两件事，
后者没有人喜欢。
''';
