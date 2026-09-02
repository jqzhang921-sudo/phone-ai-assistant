import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/self_notes.dart';

SelfNote note({
  required DateTime created,
  required int afterMinutes,
  String about = '问问饭做好了没',
}) => SelfNote(
  id: 'n1',
  conversationId: 'c1',
  about: about,
  createdAt: created,
  dueAt: created.add(Duration(minutes: afterMinutes)),
);

final t0 = DateTime(2026, 9, 2, 18, 0);

void main() {
  group('到点了没', () {
    final n = note(created: t0, afterMinutes: 40);

    test('没到点不算', () {
      expect(n.isDue(t0.add(const Duration(minutes: 39))), isFalse);
    });

    test('到点算', () {
      expect(n.isDue(t0.add(const Duration(minutes: 40))), isTrue);
    });
  });

  // 「做好了吗」问在该问的时候是关心，晚三个小时问就是没头没尾的一句。
  // 宽限跟着当初等的时长走，但要有上下限。
  group('过期作废', () {
    test('刚过点还没作废', () {
      final n = note(created: t0, afterMinutes: 40);
      expect(n.isStale(t0.add(const Duration(minutes: 45))), isFalse);
    });

    test('等 40 分钟的事，晚 40 分钟之内还能问', () {
      final n = note(created: t0, afterMinutes: 40);
      expect(n.isStale(t0.add(const Duration(minutes: 79))), isFalse);
      expect(n.isStale(t0.add(const Duration(minutes: 81))), isTrue);
    });

    // 等 10 分钟的事只给 10 分钟宽限就太紧了——手机锁屏一会儿就没了。
    test('短便签至少给半小时宽限', () {
      final n = note(created: t0, afterMinutes: 10);
      expect(n.isStale(t0.add(const Duration(minutes: 39))), isFalse);
      expect(n.isStale(t0.add(const Duration(minutes: 41))), isTrue);
    });

    // 「明天考完试问一句」这种，等了 20 小时，宽限不能也给 20 小时——
    // 那会变成后天早上补问前天的考试。
    test('长便签的宽限封顶三小时', () {
      final n = note(created: t0, afterMinutes: 20 * 60);
      final due = t0.add(const Duration(hours: 20));
      expect(n.isStale(due.add(const Duration(hours: 2, minutes: 59))), isFalse);
      expect(n.isStale(due.add(const Duration(hours: 3, minutes: 1))), isTrue);
    });
  });

  group('存和读', () {
    test('转成 JSON 再读回来，该留的都留着', () {
      final n = note(created: t0, afterMinutes: 40, about: '问问她面试怎么样');
      final back = SelfNote.fromJson(n.toJson());

      expect(back, isNotNull);
      expect(back!.about, '问问她面试怎么样');
      expect(back.conversationId, 'c1'); // 推回哪段对话全靠它
      expect(back.dueAt, n.dueAt);
    });

    test('字段缺了就当这条读不出来，别抛', () {
      expect(SelfNote.fromJson({'id': 'x'}), isNull);
      expect(SelfNote.fromJson({'about': '啥', 'dueAt': '不是时间'}), isNull);
    });
  });
}
