import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/config/reading_persona.dart';
import 'package:phone_ai_assistant/models/reading_note.dart';
import 'package:phone_ai_assistant/services/reading_note_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ReadingNote essay(String id, String text) => ReadingNote(
    id: id,
    kind: ReadingNoteKind.essay,
    content: text,
    createdAt: DateTime(2026, 9, 7),
  );

  group('随笔和收藏', () {
    test('存得下、读得回', () async {
      await ReadingNoteStore.add(essay('a', '读完《四海》有点空'));
      final all = await ReadingNoteStore.list();
      expect(all.single.content, '读完《四海》有点空');
      expect(all.single.kind, ReadingNoteKind.essay);
    });

    test('新的排在前面', () async {
      await ReadingNoteStore.add(essay('old', '旧的'));
      await ReadingNoteStore.add(
        ReadingNote(
          id: 'new',
          kind: ReadingNoteKind.essay,
          content: '新的',
          createdAt: DateTime(2026, 9, 8),
        ),
      );
      final all = await ReadingNoteStore.list();
      expect(all.first.content, '新的');
    });

    test('改内容不动创建时间', () async {
      await ReadingNoteStore.add(essay('a', '原来的'));
      final before = (await ReadingNoteStore.list()).single;
      await ReadingNoteStore.update(before.copyWith(content: '改过的'));
      final after = (await ReadingNoteStore.list()).single;
      expect(after.content, '改过的');
      expect(after.createdAt, before.createdAt);
    });

    test('删得掉', () async {
      await ReadingNoteStore.add(essay('a', '甲'));
      await ReadingNoteStore.add(essay('b', '乙'));
      await ReadingNoteStore.remove('a');
      final all = await ReadingNoteStore.list();
      expect(all.single.id, 'b');
    });

    // 存的是她自己写的东西，读不出来也不能让整页空白或者崩。
    test('存储坏掉时当空表，不抛', () async {
      SharedPreferences.setMockInitialValues({'reading_notes': '不是 JSON'});
      expect(await ReadingNoteStore.list(), isEmpty);
    });
  });

  group('从微信读书导入划线', () {
    test('导进来带上书名，并标记成 imported', () async {
      await ReadingNoteStore.importQuotes(
        bookTitle: '四海',
        lines: ['一句划线'],
      );
      final note = (await ReadingNoteStore.list()).single;
      expect(note.kind, ReadingNoteKind.quote);
      expect(note.bookTitle, '四海');
      expect(note.imported, isTrue);
    });

    // 微信读书那边没有稳定的本地 id，按 id 去重等于每导一次翻一倍。
    test('重复导入同一本不会翻倍', () async {
      await ReadingNoteStore.importQuotes(
        bookTitle: '四海',
        lines: ['甲', '乙'],
      );
      final added = await ReadingNoteStore.importQuotes(
        bookTitle: '四海',
        lines: ['甲', '乙', '丙'],
      );
      expect(added, 1);
      expect((await ReadingNoteStore.list()).length, 3);
    });

    test('不同的书可以有一模一样的句子', () async {
      await ReadingNoteStore.importQuotes(bookTitle: '甲书', lines: ['同一句']);
      final added = await ReadingNoteStore.importQuotes(
        bookTitle: '乙书',
        lines: ['同一句'],
      );
      expect(added, 1);
    });

    test('空行不算一条', () async {
      final added = await ReadingNoteStore.importQuotes(
        bookTitle: '四海',
        lines: ['  ', '', '真的一句'],
      );
      expect(added, 1);
    });

    // 需求原话：「用户要有删除的选择」。最实际的场景就是导错了要清掉，
    // 但自己写的随笔必须留着。
    test('清导入的，不动自己写的', () async {
      await ReadingNoteStore.add(essay('mine', '我自己写的'));
      await ReadingNoteStore.importQuotes(
        bookTitle: '四海',
        lines: ['划线一', '划线二'],
      );
      final removed = await ReadingNoteStore.clearImported();
      expect(removed, 2);
      final left = await ReadingNoteStore.list();
      expect(left.single.content, '我自己写的');
    });
  });

  group('读书版人设', () {
    // ⚠️ 这一组在 2026-09-08 反过来了。
    //
    // 原来守的是「先问再说」「不要替他下结论」——那是第一版的引导型设计。
    // 上线之后 Cleo 拿它跟原来那版（提示词只有一句「和用户讨论这本书」）
    // 对比，原话：
    //
    // > 之前的那种很自然，就是两个人一起讨论，而现在的就是偏问题型了，
    // > ai 一直问用户这个你怎么看怎么理解……像是让用户做阅读理解题一样
    //
    // 三条「少说多问」的规则叠在一起，把一个本来会聊天的模型改成了考官。
    // 所以那几条删了，而且**要防的是它们被加回来**——「让 AI 多提问」
    // 听起来永远像个好主意，但这条路我们已经走过一次了。
    test('该有的：安全带和加成', () {
      // 错了代价最大的两条，必须写死
      expect(readingPersona, contains('没读过就说没读过'));
      expect(readingPersona, contains('不知道的事不要编'));
      // 模型默认会收着，这两个要主动推
      expect(readingPersona, contains('允许展开'));
      expect(readingPersona, contains('敢往外拉'));
      // 真正要纠的那一条
      expect(readingPersona, contains('不要每一轮都用问题收尾'));
    });

    test('不该有的：把它推回考官的那几条', () {
      expect(readingPersona, isNot(contains('先问再说')));
      expect(readingPersona, isNot(contains('一问一给')));
      expect(readingPersona, isNot(contains('不要替他下结论')));
    });

    // 主 App 的人设写着「像发微信一样短」「默认从简」，那是陪伴型。
    // 这一份要是也短起来，讨论就展不开了。
    test('不能带上主 App 那种「说短话」的约束', () {
      expect(readingPersona, isNot(contains('像发微信')));
      expect(readingPersona, contains('允许展开'));
    });

    test('拼上书名和作者', () {
      final p = readingPromptFor(title: '四海', author: '韩寒');
      expect(p, contains('《四海》'));
      expect(p, contains('韩寒'));
      expect(p, startsWith(readingPersona));
    });

    test('没作者时不留空括号', () {
      expect(readingPromptFor(title: '四海'), isNot(contains('（）')));
      expect(readingPromptFor(title: '四海', author: '  '), isNot(contains('（')));
    });

    // 对应需求第一条：什么都不导入，直接开聊。
    test('空手开场那份会先问读了什么', () {
      expect(readingPromptOpen, contains('最近读完了什么'));
    });
  });
}
