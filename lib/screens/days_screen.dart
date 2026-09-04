import 'package:uuid/uuid.dart';
import '../services/period_forecast.dart';
import '../services/period_log.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../config/settings.dart';
import '../services/day_stats.dart';
import '../utils/dates.dart' as dates;

/// 「日子」——按天翻的月历。栖息页入口进的。
///
/// 和上面几条归档入口的区别是视角：日记/信/一隅按「类别」看存下的东西，
/// 这一页按「天」看一起发生过什么——每件小事都落在一天上，没有类别墙。
///
/// 日历自绘（项目没有任何日历组件，为这一个页面引库不划算），
/// 数据一次全量加载后按天索引（见 [DayStatsIndex]，复用现有 storage API）。
/// 横滑一下该翻到哪个月：-1 上一个月，1 下一个月，0 力道不够、不算数。
///
/// ## ⚠️ 方向别再拧反了
///
/// `primaryVelocity` **向右为正**。而向右滑的物理直觉是「把纸往右推，
/// 露出左边那张」——那是**上一个月**，和头顶左边那个箭头指的是同一件事。
///
/// 原来两个分支正好写反：向右滑翻到下个月，跟箭头相反。抽成纯函数是为了
/// 能测——手势藏在 widget 里，反了没人看得出来，只有上手才发现。
///
/// 门槛 200：低于这个当作没滑动，避免点一下手指微微一动就翻页。
int monthDeltaFromSwipe(double velocity) {
  const threshold = 200.0;
  if (velocity > threshold) return -1;
  if (velocity < -threshold) return 1;
  return 0;
}

class DaysScreen extends StatefulWidget {
  const DaysScreen({super.key});

  @override
  State<DaysScreen> createState() => _DaysScreenState();
}

class _DaysScreenState extends State<DaysScreen> {
  DayStatsIndex? _index;
  bool _loading = true;

  /// 这个月哪几天在经期里，值是「第几天」。整月一次算完——
  /// 逐格去问要读三十遍存储，那是每次翻月都白付一次的代价。
  Map<String, int> _period = const {};

  /// 下次大概什么时候。估不出来时 [PeriodForecast.hasWindow] 是 false，
  /// 那时候日历上一格都不画——见 `period_forecast.dart` 的注释。
  PeriodForecast _forecast = const PeriodForecast();

  /// 当前展示的月份，恒为月初 `DateTime(y, m, 1)`，跨月由构造自动归位。
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month, 1);
  String _aiName = '';

  static const _weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  static DateTime get _nowMonth =>
      DateTime(DateTime.now().year, DateTime.now().month, 1);

  bool get _isCurrentMonth =>
      _month.year == _nowMonth.year && _month.month == _nowMonth.month;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final index = await DayStatsIndex.collect();
    final settings = await AppSettings.load();
    final period = await _loadPeriod();
    final forecast = forecastFrom(await PeriodLog.list());
    if (!mounted) return;
    setState(() {
      _index = index;
      _aiName = settings.aiName.trim();
      _period = period;
      _forecast = forecast;
      _loading = false;
    });
  }

  Future<Map<String, int>> _loadPeriod() => PeriodLog.indexForRange(
    _month,
    DateTime(_month.year, _month.month + 1, 0),
  );

  Future<void> _reloadPeriod() async {
    final period = await _loadPeriod();
    // 记录一改，预测跟着变——它整个是从记录算出来的，没有独立状态。
    final forecast = forecastFrom(await PeriodLog.list());
    if (!mounted) return;
    setState(() {
      _period = period;
      _forecast = forecast;
    });
  }

  void _shiftMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta, 1);
    // 不允许翻进未来——下一格是今天这格「之后」的事，不是「日子」
    if (next.isAfter(_nowMonth)) return;
    _showMonth(next);
  }

  void _gotoCurrentMonth() => _showMonth(_nowMonth);

  /// 换月。**涂色是按月取的**，换完必须重算，否则新月份挂着上个月的结果。
  /// 两个入口都走这儿，省得哪天加了第三个入口又漏一次。
  void _showMonth(DateTime month) {
    setState(() => _month = month);
    _reloadPeriod();
  }

  /// 当前展示月里，有记录的（有活动的）天数。
  int get _activeDaysInMonth {
    final index = _index;
    if (index == null) return 0;
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    var n = 0;
    for (var d = 1; d <= days; d++) {
      final key = dates.dateKeyOf(DateTime(_month.year, _month.month, d));
      if (index.statsFor(key)?.hasActivity ?? false) n++;
    }
    return n;
  }

  /// 长按某天：记经期。
  ///
  /// 为什么是长按而不是点：**点开是看这天发生了什么**，那是这一页的主业。
  /// 记录是偶尔为之的动作，不该抢主手势——和板上纸条「长按撕掉」同一套分工。
  ///
  /// 面板只给当下说得通的那一两个动作，不摆一排让人挑：
  /// 这天已经在某一段里 → 只能「这天结束了」或者删掉整段；
  /// 不在 → 只能「这天来了」。
  Future<void> _markPeriod(DateTime day) async {
    final inSpan = _period[dates.dateKeyOf(day)];
    final label = '${day.month} 月 ${day.day} 日';

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        final t = Theme.of(ctx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                child: Text(
                  inSpan == null ? label : '$label · 第 $inSpan 天',
                  style: t.textTheme.titleMedium,
                ),
              ),
              if (inSpan == null)
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.drop),
                  title: const Text('这天来了'),
                  onTap: () => Navigator.pop(ctx, 'start'),
                )
              else ...[
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.check),
                  title: const Text('这天结束了'),
                  onTap: () => Navigator.pop(ctx, 'end'),
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.trashSimple),
                  title: const Text('删掉这次记录'),
                  onTap: () => Navigator.pop(ctx, 'remove'),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (action == null) return;

    if (action == 'start') {
      await PeriodLog.start(day, id: const Uuid().v4());
    } else if (action == 'end') {
      await PeriodLog.end(day);
    } else if (action == 'remove') {
      final hit = (await PeriodLog.list()).where(
        (s) => s.covers(day, DateTime.now()),
      );
      if (hit.isNotEmpty) await PeriodLog.remove(hit.first.id);
    }
    await _reloadPeriod();
  }

  void _openDay(DateTime day) {
    final stats = _index?.statsFor(dates.dateKeyOf(day));
    showModalBottomSheet(
      context: context,
      builder: (ctx) => _DaySheet(day: day, stats: stats, aiName: _aiName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('日子'),
            Text(
              _subtitle,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _monthHeader(theme),
                  const SizedBox(height: 4),
                  _weekRow(theme),
                  const SizedBox(height: 4),
                  Expanded(child: _monthGrid(context)),
                  if (!_isCurrentMonth) _backToToday(theme),
                ],
              ),
            ),
    );
  }

  String get _subtitle {
    final index = _index;
    if (index == null) return '';
    if (index.isEmpty) return '还没有记录';
    return '${_month.month} 月 · $_activeDaysInMonth 天有记录';
  }

  Widget _monthHeader(ThemeData theme) {
    return Row(
      children: [
        IconButton(
          tooltip: '上一个月',
          icon: const Icon(PhosphorIconsRegular.caretLeft),
          onPressed: () => _shiftMonth(-1),
        ),
        Expanded(
          // 月份标题用衬线体：它是一页的「名字」不是数据
          child: Center(
            child: Text(
              dates.monthLabel(_month),
              style: theme.textTheme.titleLarge?.copyWith(
                fontFamily: 'NotoSerifSC',
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '下一个月',
          icon: const Icon(PhosphorIconsRegular.caretRight),
          onPressed:
              _isCurrentMonth ? null : () => _shiftMonth(1),
        ),
      ],
    );
  }

  Widget _weekRow(ThemeData theme) {
    return Row(
      children: [
        for (final name in _weekNames)
          Expanded(
            child: Center(
              child: Text(
                name,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _monthGrid(BuildContext context) {
    final rows = dates.monthGrid(_month);
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final delta = monthDeltaFromSwipe(d.primaryVelocity ?? 0);
        if (delta != 0) _shiftMonth(delta);
      },
      // 列里不用 GridView：它的滚动和高度控制在这里都不合适，
      // 7 列均分 + Expanded 行自然等于正方形格子
      child: Column(
        children: [
          for (final row in rows)
            Expanded(
              child: Row(
                children: [
                  for (final day in row)
                    Expanded(child: _cellFor(day)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cellFor(DateTime? day) {
    final scheme = Theme.of(context).colorScheme;
    final today = DateTime.now();
    if (day == null) return const SizedBox.expand();

    final inMonth = day.month == _month.month && day.year == _month.year;
    final isToday = day.year == today.year && day.month == today.month && day.day == today.day;
    final isFuture = day.isAfter(DateTime(today.year, today.month, today.day));
    // 邻月只当占位看：淡数字是「前面/后面还有别的月」，不是可点的天
    if (!inMonth) {
      return Center(
        child: Text(
          '${day.day}',
          style: TextStyle(
            color: scheme.onSurface.withValues(alpha: 0.25),
            fontSize: 13,
          ),
        ),
      );
    }
    final hasActivity = _index?.statsFor(dates.dateKeyOf(day))?.hasActivity ?? false;
    final periodDay = _period[dates.dateKeyOf(day)];
    // 预计的那几天只画在未来：过去那几天要么真发生了（已经有 periodDay），
    // 要么没发生——两种情况下再画一个「预计」都只是噪音。
    final predicted = periodDay == null && isFuture && _forecast.covers(day);
    final label = Text(
      '${day.day}',
      style: TextStyle(
        fontSize: 15,
        fontWeight: isToday || hasActivity ? FontWeight.w600 : FontWeight.w400,
        color: isToday
            ? scheme.primary
            : isFuture
                ? scheme.onSurface.withValues(alpha: 0.25)
                : scheme.onSurface,
      ),
    );

    return InkWell(
      onTap: isFuture ? null : () => _openDay(day),
      onLongPress: isFuture ? null : () => _markPeriod(day),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 经期那几天：数字底下一圈很淡的底。
            //
            // ⚠️ 用底色而不是再加一个点。点那一行是「这天发生了什么」——
            // 日记、信、一隅都排在那儿，经期挤进去就变成了同一类东西。
            // 它不是发生在 App 里的事，是发生在她身上的事，该另开一层。
            //
            // 今天那个圈优先：今天在不在经期里都得先认得出是今天。
            // ⚠️ **实心 = 发生过，空心 = 猜的。** 这条区别必须一眼看得出来：
            // 预计的日子要是画得跟记录的一样实，她会照着它安排事情，
            // 而那正是预测最容易害人的地方。
            //
            // 今天那个圈优先级最高：今天是什么状态，都得先认得出是今天。
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: isToday
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary.withValues(alpha: 0.12),
                    )
                  : periodDay != null
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.error.withValues(alpha: 0.10),
                        )
                      : predicted
                          ? BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: scheme.error.withValues(alpha: 0.30),
                                width: 1,
                              ),
                            )
                          : null,
              child: label,
            ),
            const SizedBox(height: 3),
            // 活动点给信号，不挤占数字：4px 圆点，今天、有活动共存
            Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasActivity
                    ? scheme.primary
                    : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backToToday(ThemeData theme) {
    return Center(
      child: TextButton.icon(
        onPressed: _gotoCurrentMonth,
        icon: Icon(
          PhosphorIconsRegular.arrowLeft,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        label: Text(
          '回到今天',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 某个具体日子的活动。四点统计，哪项有数才显示哪项。
class _DaySheet extends StatelessWidget {
  final DateTime day;
  final DayStats? stats;
  final String aiName;

  const _DaySheet({required this.day, required this.stats, required this.aiName});

  String get _ai => aiName.isEmpty ? 'TA' : aiName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = stats;
    final has = s?.hasActivity ?? false;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  dates.dayLabel(day),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Divider(height: 0.5, thickness: 0.5, color: scheme.outlineVariant),
            const SizedBox(height: 10),
            if (!has) ...[
              const SizedBox(height: 24),
              Center(
                child: Column(
                  children: [
                    Text('这一天什么都没有', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    Text(
                      '那天我们什么也没留下',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ] else ...[
              if ((s?.diaryCount ?? 0) > 0)
                _StatRow(
                  icon: PhosphorIconsRegular.penNib,
                  label: '日记',
                  value: '${s!.diaryCount} 篇',
                ),
              if ((s?.userLetterCount ?? 0) > 0 || (s?.aiLetterCount ?? 0) > 0)
                _StatRow(
                  icon: PhosphorIconsRegular.envelope,
                  label: '信',
                  value:
                      '$_ai ${s!.aiLetterCount} 封 · '
                      '你 ${s.userLetterCount} 封',
                  sub: s.aiLetterCount > 0
                      ? '主动写 ${s.aiProactiveCount} 封 · '
                            '回信 ${s.aiReplyCount} 封'
                      : null,
                ),
              if ((s?.userMsgCount ?? 0) > 0 || (s?.aiMsgCount ?? 0) > 0)
                _StatRow(
                  icon: PhosphorIconsRegular.chatsTeardrop,
                  label: '消息',
                  value:
                      '你 ${s!.userMsgCount} 条 · '
                      '$_ai ${s.aiMsgCount} 条',
                ),
              if ((s?.musingCount ?? 0) > 0)
                _StatRow(
                  icon: PhosphorIconsRegular.heart,
                  label: '一隅',
                  value: '${s!.musingCount} 条',
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sub;

  const _StatRow({required this.icon, required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (sub != null)
                  Text(
                    sub!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
