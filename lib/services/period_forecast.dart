import 'period_log.dart';

/// 根据已经记下的那些,估下次大概什么时候。
///
/// ## ⚠️ 一条划死的线:这里只算数,不做任何健康判断
///
/// 不提示异常、不暗示、不建议看医生。数据反常也只说「估不准」——那是在说
/// **这份数据没法推**,不是在说她的身体怎么了。后者不是这个 App 该说的话。
///
/// ## 为什么给的是区间,不是一个日期
///
/// 真实周期是会晃的。八次记录里 26 到 31 天都出现过,那么「下次是 10 月 2 日」
/// 这句话**大概率是错的**——而错的日期画在日历上比不画更糟:她会照着它
/// 安排事情。
///
/// 所以宽度由她自己的数据决定:很规律就窄到接近一个日期,晃得厉害就宽,
/// **而宽本身就是信息**——它在诚实地说这事儿说不准。宽到没意义了
/// （见 [_irregularSpread]）就干脆不画,直说估不准。
///
/// ## 取中位数不取平均
///
/// 一次意外的长周期（漏记了一个月、或者本来就晚了很多）会把平均数拖歪好几天,
/// 中位数不受影响。这一层的数据点本来就少,单个异常值的分量太重。
class PeriodForecast {
  /// 最近几次的周期长度（相邻两次「来了」隔了多少天），从旧到新。
  final List<int> cycles;

  /// 中位数周期长度。[cycles] 为空时是 null。
  final int? medianCycle;

  /// 中位数经期长度（只数已经记了结束的那些）。
  final int? medianLength;

  /// 预计下次开始的区间。估不出来时两个都是 null。
  final DateTime? from;
  final DateTime? to;

  /// 记录太少,还推不出来。
  final bool notEnough;

  /// 间隔差得太多,推出来的区间已经宽到没意义。
  final bool irregular;

  /// 推出来的窗口整个落在过去了——她有阵子没记了。
  ///
  /// ⚠️ 这种情况**不能照样报那个日期**。记了八个月然后停三个月，
  /// 窗口早滑到过去，报出来就是一个已经作废的预计。
  /// 到底是漏记了还是真晚了，我们分不出来，那就说不知道。
  final bool stale;

  const PeriodForecast({
    this.cycles = const [],
    this.medianCycle,
    this.medianLength,
    this.from,
    this.to,
    this.notEnough = false,
    this.irregular = false,
    this.stale = false,
  });

  bool get hasWindow => from != null && to != null;

  /// 这天落在预计区间里吗。
  bool covers(DateTime day) {
    if (!hasWindow) return false;
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(from!) && !d.isAfter(to!);
  }
}

/// 至少要几个**周期**才开口估。三个周期 = 四次记录。
///
/// 两个周期也能算出一个数,但那个数没有「范围」可言——两点之间永远是一条线,
/// 看不出她晃不晃。而这一层最要紧的输出恰恰是晃的幅度。
const _minCycles = 3;

/// 只看最近这么多个周期。
///
/// 一年前的规律对现在没什么用,而且旧数据会把区间撑宽、让预测变钝。
const _lookBack = 6;

/// 修剪之后的跨度超过这么多天,就当估不准。
///
/// 九天是个经验数:再宽的区间摊在日历上等于说「这半个月里某天」,
/// 那还不如直说估不准——一个假装有用的区间比没有区间更误事。
const _irregularSpread = 9;

/// 明显是漏记出来的周期,不计入。
///
/// ⚠️ 这**不是**在替她判断哪次记错了,而是:间隔短于 15 天多半是同一次分了
/// 两条记录,长于 60 天多半是中间漏了一次。这两种都不是「周期」,拿来算
/// 中位数只会把结果带偏。剔掉的只是**算术里的输入**,她的记录一条不动。
const _sanePlausibleMin = 15;
const _sanePlausibleMax = 60;

/// 从记录里算一份预测。纯函数:所有输入都从参数进来,好测也好复算。
PeriodForecast forecastFrom(List<PeriodSpan> spans, {DateTime? now}) {
  final t = now ?? DateTime.now();
  final starts =
      spans.map((s) => s.startedAt).toList()..sort((a, b) => a.compareTo(b));

  final cycles = <int>[];
  for (var i = 1; i < starts.length; i++) {
    final gap = starts[i].difference(starts[i - 1]).inDays;
    if (gap >= _sanePlausibleMin && gap <= _sanePlausibleMax) cycles.add(gap);
  }

  final recent =
      cycles.length <= _lookBack
          ? cycles
          : cycles.sublist(cycles.length - _lookBack);

  final lengths = <int>[
    for (final s in spans)
      if (s.endedAt != null) s.endedAt!.difference(s.startedAt).inDays + 1,
  ];
  final medianLength = lengths.isEmpty ? null : _median(lengths);

  if (recent.length < _minCycles) {
    return PeriodForecast(
      cycles: recent,
      medianLength: medianLength,
      notEnough: true,
    );
  }

  final median = _median(recent);
  final (lo, hi) = _trimmedRange(recent);

  if (hi - lo > _irregularSpread) {
    return PeriodForecast(
      cycles: recent,
      medianCycle: median,
      medianLength: medianLength,
      irregular: true,
    );
  }

  final last = starts.last;
  final from = last.add(Duration(days: lo));
  final to = last.add(Duration(days: hi));

  // 整个窗口都在过去了：她有阵子没记，这个预计已经作废。
  // 报一个过去的日期比不报更糟——那看起来像是系统还在正常工作。
  final today = DateTime(t.year, t.month, t.day);
  if (to.isBefore(today)) {
    return PeriodForecast(
      cycles: recent,
      medianCycle: median,
      medianLength: medianLength,
      stale: true,
    );
  }

  return PeriodForecast(
    cycles: recent,
    medianCycle: median,
    medianLength: medianLength,
    from: from,
    to: to,
  );
}

/// 掐头去尾之后的最小/最大。
///
/// 五个数以上就各掐掉一个极端值:漏记一次就让整个预测作废太脆了,
/// 而这是统计里现成的做法（截尾极差），不是我们自己发明的规矩。
/// 数据点少于五个时不掐——那会只剩两三个数,掐完就没有范围了。
(int, int) _trimmedRange(List<int> xs) {
  final s = [...xs]..sort();
  if (s.length >= 5) {
    final inner = s.sublist(1, s.length - 1);
    return (inner.first, inner.last);
  }
  return (s.first, s.last);
}

int _median(List<int> xs) {
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  // 偶数个取中间两个的平均,四舍五入。天数没有半天。
  return s.length.isOdd ? s[mid] : ((s[mid - 1] + s[mid]) / 2).round();
}
