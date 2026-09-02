import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/utils/dates.dart';

void main() {
  group('dateKeyOf', () {
    test('零填充 YYYY-MM-DD', () {
      expect(dateKeyOf(DateTime(2026, 1, 5)), '2026-01-05');
      expect(dateKeyOf(DateTime(2026, 11, 23)), '2026-11-23');
    });

    test('倒序即日期倒序', () {
      expect(
        dateKeyOf(DateTime(2026, 9, 2)).compareTo(dateKeyOf(DateTime(2026, 9, 10))),
        lessThan(0),
      );
    });
  });

  group('monthGrid', () {
    test('2026-09：1 号是周二，月首补 1 格', () {
      // 2026-09-01 是周二（weekday=2），leading = 1
      final rows = monthGrid(DateTime(2026, 9, 1));
      expect(rows[0][0], isNull);
      expect(rows[0][1], DateTime(2026, 9, 1));
    });

    test('总格数被 7 整除，行数是 month 天数+补齐 / 7', () {
      for (final m in [DateTime(2026, 9, 1), DateTime(2026, 2, 1)]) {
        final rows = monthGrid(m);
        final cells = rows.expand((r) => r).toList();
        expect(cells.length % 7, 0);
      }
    });

    test('大小月天数正确', () {
      final june = monthGrid(DateTime(2026, 6, 1)).expand((r) => r).nonNulls;
      expect(june.length, 30);
      final july = monthGrid(DateTime(2026, 7, 1)).expand((r) => r).nonNulls;
      expect(july.length, 31);
    });

    test('闰年二月 29 天', () {
      final feb = monthGrid(DateTime(2028, 2, 1)).expand((r) => r).nonNulls;
      expect(feb.length, 29);
    });

    test('12 月翻到次年 1 月由 DateTime 构造归位', () {
      // 2027-01-01 是周五，月首补 4 格，1 号落在第一行第 5 格
      final jan = monthGrid(DateTime(2026, 13, 1));
      expect(jan.first.whereType<DateTime>().first, DateTime(2027, 1, 1));
    });
  });

  group('标签', () {
    test('monthLabel', () {
      expect(monthLabel(DateTime(2026, 9, 1)), '2026 年 9 月');
    });

    test('weekdayLabel', () {
      expect(weekdayLabel(DateTime(2026, 9, 2)), '周三');
    });

    test('dayLabel 当年不带年份，跨年带', () {
      final now = DateTime.now();
      final thisYear = dayLabel(DateTime(now.year, 3, 8));
      expect(thisYear, contains('3 月 8 日'));
      expect(thisYear, isNot(contains('${now.year} 年')));
      final otherYear = dayLabel(DateTime(now.year - 1, 3, 8));
      expect(otherYear, contains('${now.year - 1} 年'));
    });
  });
}
