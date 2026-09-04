import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/services/period_forecast.dart';
import 'package:phone_ai_assistant/services/period_log.dart';

/// 预测这一层。纯函数，所以能把每条规矩单独钉住。
///
/// 最要紧的不是「算得准」——真实周期本来就会晃，算不准是常态。
/// 要紧的是**它对自己有多不确定这件事是诚实的**：规律就窄，晃就宽，
/// 宽到没意义就直说估不准，而不是画一条假装有用的区间。
void main() {
  /// 按给定的间隔造一串记录，从 [first] 开始。
  List<PeriodSpan> spansFrom(DateTime first, List<int> gaps, {int length = 5}) {
    final out = <PeriodSpan>[];
    var d = first;
    for (var i = 0; i <= gaps.length; i++) {
      out.add(
        PeriodSpan(
          id: 'p$i',
          startedAt: d,
          endedAt: d.add(Duration(days: length - 1)),
        ),
      );
      if (i < gaps.length) d = d.add(Duration(days: gaps[i]));
    }
    return out;
  }

  /// 算一份预测，**「现在」跟着数据走**。
  ///
  /// ⚠️ 一定要显式给 now。不给就默认用真实时钟，而这些用例的数据是
  /// 2026 年初的——真实日期一往前走，窗口就滑到过去、结果变成 stale，
  /// 于是测试会在某个说不清的日子突然开始红。**测试不该有保质期。**
  ///
  /// 定在最后一次记录之后三天：那时预测窗口还在前面。
  PeriodForecast fc(List<PeriodSpan> spans) => forecastFrom(
    spans,
    now: spans.last.startedAt.add(const Duration(days: 3)),
  );

  group('数据不够就不开口', () {
    test('一条记录推不出周期', () {
      final f = fc(spansFrom(DateTime(2026, 1, 1), []));
      expect(f.notEnough, isTrue);
      expect(f.hasWindow, isFalse);
    });

    test('两个周期也不够——两点之间永远是条线，看不出晃不晃', () {
      final f = fc(spansFrom(DateTime(2026, 1, 1), [28, 29]));
      expect(f.notEnough, isTrue);
      expect(f.hasWindow, isFalse);
    });

    test('三个周期开始给', () {
      final f = fc(spansFrom(DateTime(2026, 1, 1), [28, 29, 28]));
      expect(f.notEnough, isFalse);
      expect(f.hasWindow, isTrue);
    });
  });

  group('规律的人区间就窄', () {
    test('八次都是 28，区间收成一天', () {
      final spans =
          spansFrom(DateTime(2026, 1, 1), [28, 28, 28, 28, 28, 28, 28]);
      final f = fc(spans);
      expect(f.medianCycle, 28);
      // 一点不晃 → 上下界重合，区间退化成一个日期。
      // 日期从数据里算，别手推：1/1 + 28×7 心算很容易错（是 7/16，不是 8/19，
      // 我第一版就写错了，而错的是测试不是代码）。
      expect(f.from, f.to);
      expect(f.from, spans.last.startedAt.add(const Duration(days: 28)));
    });

    test('小幅波动给一个窄区间', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [27, 28, 29, 28, 28, 29]),
      );
      expect(f.irregular, isFalse);
      expect(f.hasWindow, isTrue);
      expect(f.to!.difference(f.from!).inDays, lessThanOrEqualTo(3));
    });
  });

  group('晃得厉害就直说估不准', () {
    test('跨度超过九天不画区间', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [22, 35, 24, 38, 26, 40]),
      );
      expect(f.irregular, isTrue);
      expect(f.hasWindow, isFalse);
      // 中位数还是给的——「估不准」不等于什么都不知道
      expect(f.medianCycle, isNotNull);
    });
  });

  group('单个异常值不该毁掉整个预测', () {
    test('六次里有一次特别长，掐头去尾之后照样能给', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [28, 29, 28, 45, 28, 29]),
      );
      expect(f.irregular, isFalse, reason: '截尾极差应该把那个 45 掐掉');
      expect(f.hasWindow, isTrue);
      // [28,28,28,29,29,45] 的中位数是 28.5，天数没有半天，进位到 29。
      // 那个 45 只被掐出了「范围」，中位数照样把它算在内——中位数本来就
      // 不该被单个极端值带走，这正是不用平均数的理由。
      expect(f.medianCycle, 29);
    });

    test('少于五个周期不掐——掐完就没有范围了', () {
      final f = fc(spansFrom(DateTime(2026, 1, 1), [28, 40, 28]));
      // 三个周期，跨度 12 天 > 9，如实报估不准
      expect(f.irregular, isTrue);
    });
  });

  group('明显是漏记的不计入算术', () {
    test('间隔太长的那一段不当周期', () {
      // 中间空了 100 天：多半是漏记，不是一个周期
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [28, 100, 28, 29, 28]),
      );
      expect(f.cycles, isNot(contains(100)));
      expect(f.hasWindow, isTrue);
    });

    test('间隔太短的那一段也不当周期', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [28, 3, 28, 29, 28], length: 2),
      );
      expect(f.cycles, isNot(contains(3)));
    });

    test('但记录本身一条不动——剔掉的只是算术里的输入', () {
      final spans = spansFrom(DateTime(2026, 1, 1), [28, 100, 28, 29, 28]);
      fc(spans);
      expect(spans, hasLength(6));
    });
  });

  group('只看最近几次', () {
    test('一年前的规律不该把现在的区间撑宽', () {
      // 前四次乱，后六次很规律
      final f = fc(
        spansFrom(DateTime(2025, 1, 1), [
          20, 45, 22, 44, // 早期，应该被丢在窗口外
          28, 28, 29, 28, 28, 28,
        ]),
      );
      expect(f.cycles, hasLength(6));
      expect(f.cycles, isNot(contains(45)));
      expect(f.irregular, isFalse);
    });
  });

  group('经期长度', () {
    test('取中位数，只数记了结束的那些', () {
      final base = DateTime(2026, 1, 1);
      final f = fc([
        PeriodSpan(id: 'a', startedAt: base, endedAt: base.add(const Duration(days: 4))),
        PeriodSpan(id: 'b', startedAt: base.add(const Duration(days: 28)), endedAt: base.add(const Duration(days: 33))),
        // 没结束的这条不参与
        PeriodSpan(id: 'c', startedAt: base.add(const Duration(days: 56))),
      ]);
      expect(f.medianLength, 6); // 5 和 6 的中位数四舍五入
    });

    test('一条都没结束就没有这个数', () {
      final f = fc([
        PeriodSpan(id: 'a', startedAt: DateTime(2026, 1, 1)),
      ]);
      expect(f.medianLength, isNull);
    });
  });

  group('窗口滑到过去了', () {
    test('有阵子没记，就不该照样报那个日期', () {
      final spans = spansFrom(DateTime(2026, 1, 1), [28, 28, 29, 28, 28, 28]);
      // 最后一次记录之后三个月才打开
      final f = forecastFrom(
        spans,
        now: spans.last.startedAt.add(const Duration(days: 90)),
      );
      expect(f.stale, isTrue);
      expect(f.hasWindow, isFalse);
      // 中位数照样给——「不知道下次什么时候」不等于什么都不知道
      expect(f.medianCycle, isNotNull);
    });

    test('窗口还没过完就不算过期', () {
      final spans = spansFrom(DateTime(2026, 1, 1), [28, 28, 29, 28, 28, 28]);
      final f = fc(spans);
      final atEnd = forecastFrom(spans, now: f.to!);
      expect(atEnd.stale, isFalse);
      expect(atEnd.hasWindow, isTrue);
    });
  });

  group('区间落在哪几天', () {
    test('covers 认自己那几天，不认别的', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [27, 28, 29, 28, 28, 29]),
      );
      expect(f.covers(f.from!), isTrue);
      expect(f.covers(f.to!), isTrue);
      expect(f.covers(f.from!.subtract(const Duration(days: 1))), isFalse);
      expect(f.covers(f.to!.add(const Duration(days: 1))), isFalse);
    });

    test('估不准的时候一天都不认', () {
      final f = fc(
        spansFrom(DateTime(2026, 1, 1), [22, 35, 24, 38, 26, 40]),
      );
      expect(f.covers(DateTime(2026, 8, 1)), isFalse);
    });
  });
}
