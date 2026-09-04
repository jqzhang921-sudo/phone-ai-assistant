import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/dates.dart';

/// 经期记录。和日历画在同一张格子上，但它不是「日子」那一层的东西。
///
/// ## ⚠️ 这一层和图章、和 DayStats 都不一样
///
/// | | DayStats | 图章 | 这个 |
/// |---|---|---|---|
/// | 哪来的 | 从已有数据算出来 | 她随手贴的装饰 | **她手记的事实** |
/// | 给模型看 | 不给 | **永远不给** | 看开关 |
/// | 错了要紧吗 | 不 | 不 | **要紧** |
///
/// 所以它单独存一份，不塞进 DayStats——那边是「从别的数据推出来的统计」，
/// 混进一条手记的事实，两者的可信度就分不清了。
///
/// ## 这一层只管记，不管推
///
/// 「下次大概什么时候」在 `period_forecast.dart` 里，那边是纯函数、
/// 只吃这里的 [PeriodSpan] 列表。分开是因为两件事的性质不一样：
/// **这里存的是事实，那边算的是猜测**，混在一起迟早分不清哪个是哪个。
class PeriodSpan {
  final String id;

  /// 哪天来的。**只有日期，时刻一律归零**——这一层的粒度就是天，
  /// 留着时刻会让「同一天」的比较在边界上出错。
  final DateTime startedAt;

  /// 哪天结束的。null = 还没结束（或者她忘了记）。
  final DateTime? endedAt;

  const PeriodSpan({
    required this.id,
    required this.startedAt,
    this.endedAt,
  });

  bool get isOpen => endedAt == null;

  /// 这一段有几天。没结束的按「到今天为止」算。
  int lengthAt(DateTime now) =>
      (endedAt ?? _day(now)).difference(startedAt).inDays + 1;

  /// [day] 落在这一段里吗。没结束的段只认「开始那天到今天」，
  /// 不然它会把未来的格子也涂上。
  bool covers(DateTime day, DateTime now) {
    final d = _day(day);
    if (d.isBefore(startedAt)) return false;
    final last = endedAt ?? _day(now);
    return !d.isAfter(last);
  }

  PeriodSpan closedAt(DateTime day) =>
      PeriodSpan(id: id, startedAt: startedAt, endedAt: _day(day));

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
  };

  static PeriodSpan? fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String?;
    final start = DateTime.tryParse(j['startedAt'] as String? ?? '');
    if (id == null || start == null) return null;
    final end = DateTime.tryParse(j['endedAt'] as String? ?? '');
    return PeriodSpan(
      id: id,
      startedAt: _day(start),
      endedAt: end == null ? null : _day(end),
    );
  }
}

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

class PeriodLog {
  static const _key = 'period_spans';

  /// 让它知道这件事。**默认关着。**
  ///
  /// 这是她的身体数据，默认交出去不合适——和「通知里不显示内容」那个开关
  /// 一样，默认值该站在不交的那边，打开是一次明确的选择。
  static const _kShare = 'period_share_with_ai';

  /// **预测**给不给它看。默认关着，而且和上面那个是两件事。
  ///
  /// 「她这几天不舒服」和「她还有三天要来」是两个量级：前者是此刻的分寸，
  /// 后者是它拿着一份关于她身体的日程表。所以单独一个开关，
  /// 不跟着上面那个一起开。
  static const _kShareForecast = 'period_share_forecast';

  /// 一段没结束的记录放多久就当她忘了记。
  ///
  /// 不自动关掉它（那是替她编数据），只是不再当「正在经期」——
  /// 一段十天前开始、没结束的记录，把今天算进经期里是错的。
  static const staleAfter = Duration(days: 12);

  static Future<List<PeriodSpan>> list() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out =
          decoded
              .whereType<Map>()
              .map((m) => PeriodSpan.fromJson(Map<String, dynamic>.from(m)))
              .whereType<PeriodSpan>()
              .toList();
      out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<PeriodSpan> spans) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(spans.map((e) => e.toJson()).toList()));
  }

  // ---------------- 给不给它看 ----------------

  static Future<bool> sharedWithAi() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kShare) ?? false;
  }

  static Future<void> setSharedWithAi(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kShare, v);
  }

  /// ⚠️ 上面那个关着的时候这个不算数：它压根不知道有这回事，
  /// 更谈不上知道下次什么时候。判断收在这儿，省得每个调用点各写一遍。
  static Future<bool> forecastSharedWithAi() async {
    final sp = await SharedPreferences.getInstance();
    if (!(sp.getBool(_kShare) ?? false)) return false;
    return sp.getBool(_kShareForecast) ?? false;
  }

  static Future<void> setForecastSharedWithAi(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kShareForecast, v);
  }

  // ---------------- 记 ----------------

  /// 这天来了。
  ///
  /// 上一段还开着就先把它关掉——两段重叠是记错了，而**这一次的开始
  /// 比上一次忘了关更可信**：她此刻正在记的是眼前发生的事。
  /// 关在新的开始前一天，不是同一天（同一天既开始又结束读着很怪）。
  static Future<void> start(DateTime day, {required String id}) async {
    final d = _day(day);
    final spans = await list();
    final out = <PeriodSpan>[];
    for (final s in spans) {
      if (s.isOpen && s.startedAt.isBefore(d)) {
        out.add(s.closedAt(d.subtract(const Duration(days: 1))));
      } else {
        out.add(s);
      }
    }
    out.add(PeriodSpan(id: id, startedAt: d));
    out.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    await _save(out);
  }

  /// 这天结束了。找**开始日不晚于这天**的最后一段来收口。
  /// 找不到就什么都不做——凭空造一段是替她编数据。
  static Future<bool> end(DateTime day) async {
    final d = _day(day);
    final spans = await list();
    for (var i = spans.length - 1; i >= 0; i--) {
      final s = spans[i];
      if (!s.startedAt.isAfter(d)) {
        spans[i] = s.closedAt(d);
        await _save(spans);
        return true;
      }
    }
    return false;
  }

  static Future<void> remove(String id) async {
    final spans = await list();
    await _save(spans.where((e) => e.id != id).toList());
  }

  // ---------------- 读 ----------------

  /// 这天在不在某一段里；在的话是第几天（从 1 起）。不在返回 null。
  static Future<int?> dayIndexOf(DateTime day, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    for (final s in await list()) {
      if (!_countsAsCurrent(s, t)) continue;
      if (s.covers(day, t)) return _day(day).difference(s.startedAt).inDays + 1;
    }
    return null;
  }

  /// 整个月哪几天被涂上，一次算完给日历用。
  /// 逐天调 [dayIndexOf] 要读三十遍存储，那是每次翻月都白付一次的代价。
  static Future<Map<String, int>> indexForRange(
    DateTime from,
    DateTime to, {
    DateTime? now,
  }) async {
    final t = now ?? DateTime.now();
    final spans = await list();
    final out = <String, int>{};
    for (final s in spans) {
      if (!_countsAsCurrent(s, t)) continue;
      final last = s.endedAt ?? _day(t);
      for (var d = s.startedAt; !d.isAfter(last); d = d.add(const Duration(days: 1))) {
        if (d.isBefore(_day(from)) || d.isAfter(_day(to))) continue;
        out[dateKeyOf(d)] = d.difference(s.startedAt).inDays + 1;
      }
    }
    return out;
  }

  /// 一段没结束的记录，过了 [staleAfter] 就不再往后涂。
  ///
  /// 她忘了记结束是常事，而**忘记的代价不该是日历一路涂到年底**。
  /// 记录本身留着不动：那是她记的，不该由我们改。
  static bool _countsAsCurrent(PeriodSpan s, DateTime now) {
    if (!s.isOpen) return true;
    return _day(now).difference(s.startedAt) <= staleAfter;
  }

  /// 现在是不是在经期里；是的话第几天。
  static Future<int?> currentDay({DateTime? now}) {
    final t = now ?? DateTime.now();
    return dayIndexOf(t, now: t);
  }
}
