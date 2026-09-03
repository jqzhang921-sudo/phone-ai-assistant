import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/small_things.dart';

SmallThing thing({
  String id = 's1',
  String text = '把冬天的被子拿去洗',
  DateTime? due,
  DateTime? done,
}) => SmallThing(
  id: id,
  text: text,
  createdAt: DateTime(2026, 9, 2, 10),
  dueAt: due,
  doneAt: done,
);

void main() {
  _authorTests();

  group('存和读', () {
    test('不设截止也能存', () {
      final back = SmallThing.fromJson(thing().toJson());
      expect(back, isNotNull);
      expect(back!.text, '把冬天的被子拿去洗');
      expect(back.dueAt, isNull);
      expect(back.isDone, isFalse);
    });

    test('截止和完成时间都留得住', () {
      final t = thing(
        due: DateTime(2026, 9, 5),
        done: DateTime(2026, 9, 3, 8),
      );
      final back = SmallThing.fromJson(t.toJson())!;
      expect(back.dueAt, DateTime(2026, 9, 5));
      expect(back.isDone, isTrue);
    });

    test('字段缺了就当读不出来，别抛', () {
      expect(SmallThing.fromJson({'id': 'x'}), isNull);
      expect(SmallThing.fromJson({'text': '啥', 'createdAt': '不是时间'}), isNull);
    });
  });

  // ⚠️ 这一组钉的是小事和便签最根本的差别。
  // 便签会自动作废（问晚了就没意义），小事**绝不能**——那不叫过期，叫丢东西。
  group('小事不会自己消失', () {
    test('过了截止时间也还在，只是显示成过期', () {
      final t = thing(due: DateTime(2026, 1, 1)); // 早就过了
      expect(t.isDone, isFalse); // 还在，没被作废
    });

    test('勾掉不是删掉：只记一个时间', () {
      final done = thing().copyWith(doneAt: DateTime(2026, 9, 2, 12));
      expect(done.isDone, isTrue);
      expect(done.text, thing().text); // 内容原样留着，撤销才有东西可恢复
    });

    test('撤销勾选要能真的撤回来', () {
      final done = thing().copyWith(doneAt: DateTime(2026, 9, 2, 12));
      expect(done.copyWith(clearDone: true).isDone, isFalse);
    });
  });
}

// ── 谁贴的 ────────────────────────────────────────────────────────
//
// 这个字段是给**模型**读的，板上不显示（见 SmallThingAuthor 的注释）。
// 所以它唯一要保证的就是：存得住、读得回、老数据不崩。
void _authorTests() {
  group('谁贴的', () {
    test('存得住读得回', () {
      for (final a in SmallThingAuthor.values) {
        final back = SmallThing.fromJson(
          SmallThing(
            id: 'x',
            text: '今天云很好看',
            createdAt: DateTime(2026, 9, 3),
            author: a,
          ).toJson(),
        );
        expect(back!.author, a);
      }
    });

    test('老纸条没这个字段，读出来是 null，不是崩', () {
      final back = SmallThing.fromJson({
        'id': 'old',
        'text': '把冬天的被子拿去洗',
        'createdAt': '2026-08-20T10:00:00.000',
      });
      expect(back, isNotNull);
      expect(back!.author, isNull);
    });

    test('认不出来的值当没有', () {
      final back = SmallThing.fromJson({
        'id': 'weird',
        'text': '去拿快递',
        'createdAt': '2026-08-20T10:00:00.000',
        'author': 'cat',
      });
      expect(back, isNotNull);
      expect(back!.author, isNull);
    });

    test('勾掉之后作者还在', () {
      final t = SmallThing(
        id: 'x',
        text: '去拿快递',
        createdAt: DateTime(2026, 9, 3),
        author: SmallThingAuthor.ai,
      ).copyWith(doneAt: DateTime(2026, 9, 4));
      expect(t.author, SmallThingAuthor.ai);
      expect(t.isDone, isTrue);
    });
  });
}
