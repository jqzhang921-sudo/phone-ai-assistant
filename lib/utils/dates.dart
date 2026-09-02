/// 「日子」功能专用的日期工具。
///
/// 只放这一页要用的函数，不去动 diary/musing/storage 里已有的 dateKey 实现——
/// 那些是既有数据契约（storage_service 注释：键是契约，别改名），
/// 动了徒增 diff 面。这里只从「新代码用同一个契约」这个角度加入口。
library;

/// 零填充日期键 `YYYY-MM-DD`，与 DiaryEntry.dateKey / MusingEntry.dateKey
/// 同一契约：字符串倒序即日期倒序，分桶/比较都拿它当唯一键。
String dateKeyOf(DateTime d) {
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 某个月的周历格：周一起始、7 列一行，首尾不足一行的地方补 null。
///
/// [month] 只取 year/month，跨月/闰月由 DateTime 构造自动归位
/// （`DateTime(y, m + 1, 0)` 永远给出 m 月最后一天）。
List<List<DateTime?>> monthGrid(DateTime month) {
  final first = DateTime(month.year, month.month, 1);
  // DateTime.weekday：周一=1 … 周日=7，减 1 变成「前面补几个 null」
  final leading = first.weekday - 1;
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  final cells = <DateTime?>[
    ...List<DateTime?>.filled(leading, null),
    for (var d = 1; d <= daysInMonth; d++) DateTime(month.year, month.month, d),
  ];
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return [for (var i = 0; i < cells.length; i += 7) cells.sublist(i, i + 7)];
}

/// 月份头标题，如 `2026 年 9 月`（NotoSerifSC 渲染，不带零填充）。
String monthLabel(DateTime m) => '${m.year} 年 ${m.month} 月';

/// 某天的读法：`9 月 2 日 · 周三`；跨年带上年份。
///
/// 和 musing_corner_screen `_dateLabel` 同款思路——
/// 「今年」是默认语境，只有跨年才值得写年份。
String dayLabel(DateTime d) {
  final now = DateTime.now();
  final date = d.year == now.year
      ? '${d.month} 月 ${d.day} 日'
      : '${d.year} 年 ${d.month} 月 ${d.day} 日';
  return '$date · ${weekdayLabel(d)}';
}

/// `周三` 这类标题。周一=1 起点，与月历列头对齐。
String weekdayLabel(DateTime d) {
  const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  return names[d.weekday - 1];
}
