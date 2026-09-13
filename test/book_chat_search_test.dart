import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/book_chat_search.dart';

/// 搜索要解决的是「记得一句话，忘了书名」——按书排的列表在这时候帮不上忙。
/// 这个文件盯的是**搜出来的那条对不对**：命中判定、片段裁剪、结果条数。

SearchableChat _chat(String id, String title, List<(bool, String)> msgs) =>
    SearchableChat(
      bookId: id,
      title: title,
      messages: [
        for (final (isUser, content) in msgs)
          SearchableMessage(isUser: isUser, content: content),
      ],
      lastAt: DateTime(2026, 9, 1),
    );

/// 常用的一本书：只有一条能命中的消息。
SearchableChat _one(String content) => _chat('b1', '金枝玉叶', [(false, content)]);

void main() {
  group('分词', () {
    test('中文不切——整串是一个词', () {
      expect(BookChatSearch.terms('金枝玉叶'), ['金枝玉叶']);
    });

    test('空白处切开，多余的空格扔掉', () {
      expect(BookChatSearch.terms('  金枝   玉叶 '), ['金枝', '玉叶']);
    });

    test('只有空白等于没搜', () {
      expect(BookChatSearch.terms('   '), isEmpty);
    });
  });

  group('命中', () {
    test('说过的话搜得到，片段里带着那句话', () {
      final hits = BookChatSearch.run([
        _one('上次说的那个效应叫什么来着'),
      ], BookChatSearch.terms('效应'));
      expect(hits, hasLength(1));
      expect(hits.first.snippet, contains('效应'));
      expect(hits.first.title, '金枝玉叶');
      expect(hits.first.isUser, isFalse);
    });

    test('谁说的记在结果上', () {
      final hits = BookChatSearch.run([
        _chat('b1', '金枝玉叶', [(true, '我记得有个效应')]),
      ], BookChatSearch.terms('效应'));
      expect(hits.first.isUser, isTrue);
    });

    test('英文不分大小写', () {
      final hits = BookChatSearch.run([
        _one('这叫 Mere Exposure Effect'),
      ], BookChatSearch.terms('mere exposure'));
      expect(hits, hasLength(1));
    });

    test('中文按整串匹配，拆开的字不算', () {
      // 「金」「枝」「玉」「叶」都出现过，但没连在一起——不该命中。
      final hits = BookChatSearch.run([
        _one('金子和树枝，还有玉和叶子'),
      ], BookChatSearch.terms('金枝玉叶'));
      expect(hits, isEmpty);
    });

    test('多个词要全都出现——多打一个字是收窄，不是放宽', () {
      final chats = [
        _chat('b1', '甲书', [(true, '只提到效应'), (true, '提到效应也提到睡眠')]),
      ];
      final hits = BookChatSearch.run(chats, BookChatSearch.terms('效应 睡眠'));
      expect(hits, hasLength(1));
      expect(hits.first.snippet, contains('睡眠'));
    });
  });

  group('取哪几条', () {
    test('一场讨论最多三条——不然一本书能把整屏占满', () {
      final hits = BookChatSearch.run([
        _chat('b1', '金枝玉叶', [
          for (var i = 0; i < 8; i++) (true, '第 $i 条，都提到效应'),
        ]),
      ], BookChatSearch.terms('效应'));
      expect(hits, hasLength(3));
    });

    test('一场里从后往前取——最近说的那句才是要找的', () {
      final hits = BookChatSearch.run([
        _chat('b1', '金枝玉叶', [(true, '早先提过效应'), (true, '后来又说了一次效应')]),
      ], BookChatSearch.terms('效应'));
      expect(hits.first.snippet, contains('后来'));
      expect(hits.last.snippet, contains('早先'));
    });

    test('跨书时先给最近聊过的那本', () {
      final older = SearchableChat(
        bookId: 'b1',
        title: '早的书',
        messages: const [SearchableMessage(isUser: true, content: '效应')],
        lastAt: DateTime(2026, 1, 1),
      );
      final newer = SearchableChat(
        bookId: 'b2',
        title: '近的书',
        messages: const [SearchableMessage(isUser: true, content: '效应')],
        lastAt: DateTime(2026, 9, 1),
      );
      // load() 已经排好序，run() 不再动它——顺序是它给的。
      final hits = BookChatSearch.run([
        newer,
        older,
      ], BookChatSearch.terms('效应'));
      expect(hits.map((h) => h.title), ['近的书', '早的书']);
    });
  });

  group('片段', () {
    test('太长就裁短，两头带省略号', () {
      final hits = BookChatSearch.run([
        _one('${'前' * 100}效应${'后' * 100}'),
      ], BookChatSearch.terms('效应'));
      final s = hits.first.snippet;
      expect(s, contains('效应'));
      expect(s, startsWith('…'));
      expect(s, endsWith('…'));
      expect(s.length, lessThan(90));
    });

    test('开头就是命中词时不加前省略号', () {
      final hits = BookChatSearch.run([
        _one('效应这件事'),
      ], BookChatSearch.terms('效应'));
      expect(hits.first.snippet, startsWith('效应'));
    });

    test('换行压成空格——列表里每条只占一行', () {
      final hits = BookChatSearch.run([
        _one('第一段\n\n效应在第二段'),
      ], BookChatSearch.terms('效应'));
      expect(hits.first.snippet, contains('第一段 效应在第二段'));
      expect(hits.first.snippet, isNot(contains('\n')));
    });

    test('不把一个 emoji 切成两半', () {
      // 9 个 emoji 占 18 个码元，'a' 落在 18，命中词从 19 开始——
      // 前 18 个字的窗口正好切在第 1 个 emoji 的中间。
      final content = '😀' * 9 + 'a' + '目标词' + 'b' * 80;
      final hits = BookChatSearch.run([
        _one(content),
      ], BookChatSearch.terms('目标词'));
      expect(hits.first.snippet, startsWith('😀'));
      expect(hits.first.snippet, contains('目标词'));
    });
  });

  group('空查询', () {
    test('没输入词就没有结果，不是「全都算命中」', () {
      expect(BookChatSearch.run([_one('效应')], const []), isEmpty);
    });

    test('没有记录时不抛', () {
      expect(BookChatSearch.run(const [], BookChatSearch.terms('效应')), isEmpty);
    });
  });
}
