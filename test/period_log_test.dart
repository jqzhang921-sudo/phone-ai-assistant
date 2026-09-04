import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/period_log.dart';
import 'package:phone_ai_assistant/utils/dates.dart';

/// 经期记录。这一层和图章不一样：**记错了是要紧的**，所以规矩得测。
///
/// 三件事最容易出错：忘了记结束、两段重叠、翻月的时候涂错格子。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  DateTime d(int m, int day) => DateTime(2026, m, day);

  group('记', () {
    test('记一天来了，那天就在里面', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      expect(await PeriodLog.dayIndexOf(d(9, 3), now: d(9, 3)), 1);
      expect(await PeriodLog.dayIndexOf(d(9, 2), now: d(9, 3)), isNull);
    });

    test('没结束的段一直数到今天', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      expect(await PeriodLog.dayIndexOf(d(9, 5), now: d(9, 5)), 3);
    });

    test('没结束的段不往未来涂', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      expect(await PeriodLog.dayIndexOf(d(9, 8), now: d(9, 5)), isNull);
    });

    test('结束之后就到那天为止', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      await PeriodLog.end(d(9, 7));
      expect(await PeriodLog.dayIndexOf(d(9, 7), now: d(9, 20)), 5);
      expect(await PeriodLog.dayIndexOf(d(9, 8), now: d(9, 20)), isNull);
    });

    test('时刻一律归零——同一天不该因为几点记的就对不上', () async {
      await PeriodLog.start(DateTime(2026, 9, 3, 23, 40), id: 'a');
      expect(
        await PeriodLog.dayIndexOf(DateTime(2026, 9, 3, 1), now: d(9, 3)),
        1,
      );
    });
  });

  group('忘了记结束', () {
    test('新的一段开始时，把上一段收在前一天', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      await PeriodLog.start(d(10, 1), id: 'b');
      final spans = await PeriodLog.list();
      expect(spans, hasLength(2));
      expect(spans.first.endedAt, d(9, 30));
      expect(spans.last.isOpen, isTrue);
    });

    test('放太久的开口段不再算「正在经期」', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      // 宽限 12 天：第 15 天还算在里面就荒唐了
      expect(await PeriodLog.currentDay(now: d(9, 8)), 6);
      expect(await PeriodLog.currentDay(now: d(9, 30)), isNull);
    });

    test('但记录本身留着不动——那是她记的，不该替她改', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      expect(await PeriodLog.currentDay(now: d(9, 30)), isNull);
      expect(await PeriodLog.list(), hasLength(1));
    });

    test('过后补记结束，照样收得回来', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      expect(await PeriodLog.end(d(9, 8)), isTrue);
      expect(await PeriodLog.dayIndexOf(d(9, 8), now: d(9, 30)), 6);
    });

    test('没有可收的段就什么都不做，不凭空造一段', () async {
      expect(await PeriodLog.end(d(9, 8)), isFalse);
      expect(await PeriodLog.list(), isEmpty);
    });
  });

  group('整月一次算完', () {
    test('只涂这个月，段跨月也只给这个月那半截', () async {
      await PeriodLog.start(d(9, 28), id: 'a');
      await PeriodLog.end(d(10, 3));
      final sep = await PeriodLog.indexForRange(
        d(9, 1),
        d(9, 30),
        now: d(10, 20),
      );
      expect(sep.keys.toSet(), {
        for (var i = 28; i <= 30; i++) dateKeyOf(d(9, i)),
      });
      expect(sep[dateKeyOf(d(9, 28))], 1);
      expect(sep[dateKeyOf(d(9, 30))], 3);

      final oct = await PeriodLog.indexForRange(
        d(10, 1),
        d(10, 31),
        now: d(10, 20),
      );
      // 跨月那半截接着数，不从 1 重来
      expect(oct[dateKeyOf(d(10, 1))], 4);
      expect(oct[dateKeyOf(d(10, 3))], 6);
      expect(oct[dateKeyOf(d(10, 4))], isNull);
    });

    test('和逐天问的结果一致', () async {
      await PeriodLog.start(d(9, 10), id: 'a');
      await PeriodLog.end(d(9, 14));
      final bulk = await PeriodLog.indexForRange(d(9, 1), d(9, 30), now: d(9, 20));
      for (var i = 1; i <= 30; i++) {
        expect(
          bulk[dateKeyOf(d(9, i))],
          await PeriodLog.dayIndexOf(d(9, i), now: d(9, 20)),
          reason: '9 月 $i 日对不上',
        );
      }
    });
  });

  group('给不给它看', () {
    test('默认不给——这是身体数据，交出去该是一次明确的选择', () async {
      expect(await PeriodLog.sharedWithAi(), isFalse);
    });

    test('开关存得住', () async {
      await PeriodLog.setSharedWithAi(true);
      expect(await PeriodLog.sharedWithAi(), isTrue);
      await PeriodLog.setSharedWithAi(false);
      expect(await PeriodLog.sharedWithAi(), isFalse);
    });
  });

  group('删', () {
    test('删掉一段，那几天就空了', () async {
      await PeriodLog.start(d(9, 3), id: 'a');
      await PeriodLog.end(d(9, 7));
      await PeriodLog.remove('a');
      expect(await PeriodLog.list(), isEmpty);
      expect(await PeriodLog.dayIndexOf(d(9, 5), now: d(9, 20)), isNull);
    });
  });

  group('存坏了不崩', () {
    test('字段缺了当读不出来', () {
      expect(PeriodSpan.fromJson({'id': 'x'}), isNull);
      expect(PeriodSpan.fromJson({'startedAt': '不是时间'}), isNull);
    });

    test('存得住读得回', () {
      final back = PeriodSpan.fromJson(
        PeriodSpan(id: 'x', startedAt: d(9, 3), endedAt: d(9, 7)).toJson(),
      );
      expect(back!.startedAt, d(9, 3));
      expect(back.endedAt, d(9, 7));
      expect(back.isOpen, isFalse);
    });
  });
}
