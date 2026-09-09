import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/book_chat_store.dart';

/// 首页那一栏为什么会漏掉一整类记录，写在 [BookChatStore] 的注释里。
/// 这个文件盯的是**列出来的那一条对不对**。

final _fallback = DateTime(2026, 9, 1);

Map<String, dynamic> _conv({
  String title = '金枝玉叶',
  List<Map<String, dynamic>>? messages,
}) => {
  'id': 'book_b1',
  'title': title,
  'updatedAt': '2026-09-05T10:00:00.000',
  'messages':
      messages ??
      [
        {
          'role': 'user',
          'content': '你读过这本书吗',
          'timestamp': '2026-09-07T21:04:00.000',
        },
        {
          'role': 'assistant',
          'content': '没读过——说实话我连你说的是哪本都不能确定。',
          'timestamp': '2026-09-07T21:05:00.000',
        },
      ],
};

void main() {
  group('列一条出来', () {
    test('书名、条数、最后一句、时间都对', () {
      final e = BookChatStore.fromJson(
        _conv(),
        bookId: 'b1',
        fallbackAt: _fallback,
      );
      expect(e, isNotNull);
      expect(e!.title, '金枝玉叶');
      expect(e.bookId, 'b1');
      expect(e.messageCount, 2);
      expect(e.preview, startsWith('没读过'));
      expect(e.lastAt, DateTime(2026, 9, 7, 21, 5));
    });

    test('预览里的换行压成空格，不撑成两行', () {
      final e = BookChatStore.fromJson(
        _conv(
          messages: [
            {
              'role': 'assistant',
              'content': '第一段\n\n第二段',
              'timestamp': '2026-09-07T21:00:00.000',
            },
          ],
        ),
        bookId: 'b1',
        fallbackAt: _fallback,
      );
      expect(e!.preview, '第一段 第二段');
    });

    test('太长的预览截断', () {
      final e = BookChatStore.fromJson(
        _conv(
          messages: [
            {
              'role': 'assistant',
              'content': '啊' * 200,
              'timestamp': '2026-09-07T21:00:00.000',
            },
          ],
        ),
        bookId: 'b1',
        fallbackAt: _fallback,
      );
      expect(e!.preview.length, lessThan(70));
      expect(e.preview, endsWith('…'));
    });
  });

  group('不该列的', () {
    test('一条消息都没有的不列——进去看了一眼没说话，不占一行', () {
      expect(
        BookChatStore.fromJson(
          _conv(messages: []),
          bookId: 'b1',
          fallbackAt: _fallback,
        ),
        isNull,
      );
    });

    test('只有空消息的不列', () {
      expect(
        BookChatStore.fromJson(
          _conv(
            messages: [
              {'role': 'user', 'content': '   ', 'timestamp': ''},
            ],
          ),
          bookId: 'b1',
          fallbackAt: _fallback,
        ),
        isNull,
      );
    });

    test('结构不对的不抛，返回 null', () {
      expect(
        BookChatStore.fromJson(
          {'messages': '不是数组'},
          bookId: 'b1',
          fallbackAt: _fallback,
        ),
        isNull,
      );
      expect(
        BookChatStore.fromJson({}, bookId: 'b1', fallbackAt: _fallback),
        isNull,
      );
    });
  });

  group('老记录', () {
    // 「书名写进 title」是 2026-09-07 才加的。在那之前存下的记录 title 是
    // 「新对话」——一整列全叫这个等于没列，所以退回 bookId，至少能区分。
    // （BookChatScreen 每次打开会把书名补回去，所以这是过渡态。）
    test('title 是「新对话」时退回 bookId', () {
      final e = BookChatStore.fromJson(
        _conv(title: '新对话'),
        bookId: 'adhoc_12345',
        fallbackAt: _fallback,
      );
      expect(e!.title, 'adhoc_12345');
    });

    test('消息没时间戳时退回 updatedAt', () {
      final e = BookChatStore.fromJson(
        _conv(
          messages: [
            {'role': 'user', 'content': '在吗'},
          ],
        ),
        bookId: 'b1',
        fallbackAt: _fallback,
      );
      expect(e!.lastAt, DateTime(2026, 9, 5, 10, 0));
    });

    test('updatedAt 也没有就退回文件时间——排序总得有个依据', () {
      final e = BookChatStore.fromJson(
        {
          'messages': [
            {'role': 'user', 'content': '在吗'},
          ],
        },
        bookId: 'b1',
        fallbackAt: _fallback,
      );
      expect(e!.lastAt, _fallback);
    });
  });

  _titleRecovery();
}

/// 标题从系统提示里捞回来 —— 老记录没写 title，退回 bookId 的话列表上
/// 就是一排 `adhoc_584142370`，记录是回来了但认不出是哪本。
void _titleRecovery() {
  group('老记录的书名', () {
    test('title 是「新对话」时从系统提示里捞', () {
      final e = BookChatStore.fromJson({
        'title': '新对话',
        'systemPrompt': '你和用户正在聊一部他读过的作品。⋯⋯\n\n这次聊的是《金枝玉叶》（余耕）。',
        'messages': [
          {'role': 'user', 'content': '在', 'timestamp': '2026-09-07T21:00:00.000'},
        ],
      }, bookId: 'adhoc_584142370', fallbackAt: DateTime(2026, 9, 1));
      expect(e!.title, '金枝玉叶');
    });

    test('系统提示里也没有才退回 bookId', () {
      final e = BookChatStore.fromJson({
        'title': '新对话',
        'systemPrompt': '随便什么',
        'messages': [
          {'role': 'user', 'content': '在', 'timestamp': '2026-09-07T21:00:00.000'},
        ],
      }, bookId: 'adhoc_1', fallbackAt: DateTime(2026, 9, 1));
      expect(e!.title, 'adhoc_1');
    });

    test('存了真书名的优先，不去碰系统提示', () {
      final e = BookChatStore.fromJson({
        'title': '白夜行',
        'systemPrompt': '这次聊的是《金枝玉叶》。',
        'messages': [
          {'role': 'user', 'content': '在', 'timestamp': '2026-09-07T21:00:00.000'},
        ],
      }, bookId: 'b1', fallbackAt: DateTime(2026, 9, 1));
      expect(e!.title, '白夜行');
    });
  });
}
