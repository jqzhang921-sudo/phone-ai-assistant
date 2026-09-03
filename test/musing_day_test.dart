import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/utils/dates.dart';

/// 「我想说」的一天从凌晨 5 点算起。
///
/// 要保证的是那把刀切在对的地方：**深夜那段算前一天**。原来用自然日历日，
/// 零点一过就换键、就重新生成——而那一刻「今天」是空的，等于每天都在手上
/// 素材最少的时候开口；反过来聊到一两点的话，刚攒的一晚上又被切在了外面。
void main() {
  group('我想说的一天', () {
    test('白天属于当天', () {
      expect(musingDayKey(DateTime(2026, 9, 4, 9)), '2026-09-04');
      expect(musingDayKey(DateTime(2026, 9, 4, 23, 59)), '2026-09-04');
    });

    test('过了零点还算前一天——这就是这次要修的那一刀', () {
      expect(musingDayKey(DateTime(2026, 9, 5, 0, 1)), '2026-09-04');
      expect(musingDayKey(DateTime(2026, 9, 5, 2, 30)), '2026-09-04');
      expect(musingDayKey(DateTime(2026, 9, 5, 4, 59)), '2026-09-04');
    });

    test('5 点整翻篇', () {
      expect(musingDayKey(DateTime(2026, 9, 5, 5)), '2026-09-05');
    });

    test('起点就是那天 5 点，取素材的窗口拿它往回推一天', () {
      final start = musingDayStart(DateTime(2026, 9, 5, 2, 30));
      expect(start, DateTime(2026, 9, 4, 5));
      // 素材窗口 = [起点-24h, 起点)：正好盖住 9/3 5:00 到 9/4 5:00，
      // 包含 9/3 深夜那段。
      expect(start.subtract(const Duration(days: 1)), DateTime(2026, 9, 3, 5));
    });

    test('跨月跨年不出错', () {
      expect(musingDayKey(DateTime(2026, 10, 1, 3)), '2026-09-30');
      expect(musingDayKey(DateTime(2027, 1, 1, 3)), '2026-12-31');
    });
  });
}
