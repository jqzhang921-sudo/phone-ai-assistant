import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/models/conversation.dart';
import 'package:phone_ai_assistant/models/diary_entry.dart';
import 'package:phone_ai_assistant/models/letter.dart';
import 'package:phone_ai_assistant/models/musing_entry.dart';
import 'package:phone_ai_assistant/services/day_stats.dart';

ChatMessage _msg(MessageRole role, DateTime ts) =>
    ChatMessage(id: 'm', role: role, content: 'x', timestamp: ts);

Conversation _conv(List<ChatMessage> msgs) => Conversation(
  id: 'c1',
  title: 't',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  messages: msgs,
);

Letter _letter(LetterAuthor author, DateTime ts, {String? replyToId}) =>
    Letter(
      id: 'l',
      author: author,
      content: 'x',
      createdAt: ts,
      replyToId: replyToId,
    );

DiaryEntry _diary(DateTime d) => DiaryEntry(id: 'd', date: d, content: 'x');

MusingEntry _musing(DateTime d) =>
    MusingEntry(id: 'u', date: d, content: 'x');

DayStatsIndex _build({
  List<Conversation> convs = const [],
  List<DiaryEntry> diaries = const [],
  List<Letter> letters = const [],
  List<MusingEntry> musings = const [],
}) => DayStatsIndex.build(
  conversations: convs,
  diaries: diaries,
  letters: letters,
  musings: musings,
);

void main() {
  group('消息分桶', () {
    test('user / assistant 各计各的，system 等不进数', () {
      final index = _build(convs: [
        _conv([
          _msg(MessageRole.user, DateTime(2026, 9, 2, 9)),
          _msg(MessageRole.assistant, DateTime(2026, 9, 2, 9, 5)),
          _msg(MessageRole.system, DateTime(2026, 9, 2, 9, 6)),
          _msg(MessageRole.toolCall, DateTime(2026, 9, 2, 9, 7)),
          _msg(MessageRole.toolResult, DateTime(2026, 9, 2, 9, 8)),
        ]),
      ]);
      final s = index.statsFor('2026-09-02')!;
      expect(s.userMsgCount, 1);
      expect(s.aiMsgCount, 1);
    });

    test('同一段对话跨两天的消息分属两天', () {
      final index = _build(convs: [
        _conv([
          _msg(MessageRole.user, DateTime(2026, 8, 31, 23, 30)),
          _msg(MessageRole.assistant, DateTime(2026, 8, 31, 23, 35)),
          _msg(MessageRole.user, DateTime(2026, 9, 1, 0, 10)),
        ]),
      ]);
      expect(index.statsFor('2026-08-31')!.userMsgCount, 1);
      expect(index.statsFor('2026-08-31')!.aiMsgCount, 1);
      expect(index.statsFor('2026-09-01')!.userMsgCount, 1);
    });

    test('多段对话同一天的消息累加', () {
      final index = _build(convs: [
        _conv([_msg(MessageRole.user, DateTime(2026, 9, 2, 8))]),
        _conv([_msg(MessageRole.user, DateTime(2026, 9, 2, 20))]),
      ]);
      expect(index.statsFor('2026-09-02')!.userMsgCount, 2);
    });
  });

  group('信拆分', () {
    test('replyToId null = 主动写，非 null = 回信', () {
      final index = _build(letters: [
        _letter(LetterAuthor.ai, DateTime(2026, 9, 1, 10)),
        _letter(LetterAuthor.ai, DateTime(2026, 9, 1, 12), replyToId: 'l0'),
      ]);
      final s = index.statsFor('2026-09-01')!;
      expect(s.aiProactiveCount, 1);
      expect(s.aiReplyCount, 1);
      expect(s.aiLetterCount, 2);
      expect(s.userLetterCount, 0);
    });

    test('用户写的信独立计数', () {
      final index = _build(letters: [
        _letter(LetterAuthor.user, DateTime(2026, 9, 3, 21)),
      ]);
      final s = index.statsFor('2026-09-03')!;
      expect(s.userLetterCount, 1);
      expect(s.aiLetterCount, 0);
    });
  });

  group('日记 / 一隅', () {
    test('一天多篇日记累加', () {
      final index = _build(diaries: [
        _diary(DateTime(2026, 9, 4, 22)),
        _diary(DateTime(2026, 9, 4, 23)),
      ]);
      expect(index.statsFor('2026-09-04')!.diaryCount, 2);
    });

    test('一隅按生成日 dateKey 归属', () {
      final index = _build(musings: [
        _musing(DateTime(2026, 9, 5)),
      ]);
      expect(index.statsFor('2026-09-05')!.musingCount, 1);
      // 无记录的天不建条目——statsFor 是 null，调用方用 ?. 落回 0
      expect(index.statsFor('2026-09-06'), isNull);
    });
  });

  group('hasActivity / 空索引', () {
    test('只有任一维非零即为真', () {
      expect(
        _build(musings: [_musing(DateTime(2026, 9, 5))])
            .statsFor('2026-09-05')!
            .hasActivity,
        isTrue,
      );
      expect(
        _build(musings: [_musing(DateTime(2026, 9, 5))])
            .statsFor('2026-09-06'),
        isNull,
      );
    });

    test('空输入：isEmpty，statsFor 返回 null', () {
      final index = _build();
      expect(index.isEmpty, isTrue);
      expect(index.statsFor('2026-09-01'), isNull);
      expect(index.activeDayCount, 0);
    });

    test('有记录的天数 indexed correctly', () {
      final index = _build(diaries: [_diary(DateTime(2026, 9, 4))]);
      expect(index.isEmpty, isFalse);
      expect(index.activeDayCount, 1);
    });
  });
}
