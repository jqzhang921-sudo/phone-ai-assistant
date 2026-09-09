import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/shared_text.dart';

void main() {
  group('分享一本书', () {
    // 番茄分享书籍的典型样子：一句推广语 + 书名 + 链接。
    // 剥完之后应该只剩书名，正文是空的——不然这句推广语会被当成摘录存进收藏。
    test('番茄的分享文案只留下书名', () {
      final r = SharedReading.parse(
        '我在番茄免费小说看《诡秘之主》，太好看了，快来一起看吧\n'
        'https://fanqienovel.com/reader/123456',
      );
      expect(r.bookTitle, '诡秘之主');
      expect(r.body, isEmpty);
      expect(r.isExcerpt, isFalse);
    });

    test('只有一条链接，什么都解析不出来', () {
      final r = SharedReading.parse('https://fanqienovel.com/page/7');
      expect(r.isEmpty, isTrue);
    });

    // subject 和 text 被原生那边拼成两行，书名可能只在其中一行里。
    test('书名在单独一行也认得出', () {
      final r = SharedReading.parse('《活着》\n点击链接免费阅读 http://a.b/c');
      expect(r.bookTitle, '活着');
      expect(r.body, isEmpty);
    });

    // 有人直接在备忘录里选中两个字分享过来，那两个字就是书名。
    test('没有书名号的短文字当成书名', () {
      final r = SharedReading.parse('围城');
      expect(r.bookTitle, '围城');
      expect(r.body, isEmpty);
    });
  });

  group('分享一段原文', () {
    test('带出处的摘录：正文和书名分开', () {
      final r = SharedReading.parse(
        '人是为了活着本身而活着，而不是为了活着之外的任何事物而活着。\n'
        '——《活着》 余华',
      );
      expect(r.bookTitle, '活着');
      expect(r.body, startsWith('人是为了活着本身'));
      expect(r.body, isNot(contains('余华')));
      expect(r.isExcerpt, isTrue);
    });

    // 长按选中分享（ACTION_PROCESS_TEXT）过来的就是光秃秃一段，没有出处。
    // 不能瞎猜书名——界面会问他。
    test('没有出处的一段：书名为 null，正文原样留着', () {
      const text = '他忽然明白，所谓故乡，不过是祖先流浪的最后一站。';
      final r = SharedReading.parse(text);
      expect(r.bookTitle, isNull);
      expect(r.body, text);
      expect(r.isExcerpt, isTrue);
    });

    test('两头的引号剥掉', () {
      final r = SharedReading.parse('「我们所经历的每个平凡的日常，也许就是奇迹」');
      expect(r.body, '我们所经历的每个平凡的日常，也许就是奇迹');
    });

    test('多段正文之间的换行保留', () {
      final r = SharedReading.parse('第一段话在这里。\n第二段话在这里。\n——《某书》');
      expect(r.bookTitle, '某书');
      expect(r.body, '第一段话在这里。\n第二段话在这里。');
    });

    // 正文里夹着链接的情况：链接剥掉，句子留下，别把整行都扔了。
    test('正文里的链接剥掉，句子留着', () {
      final r = SharedReading.parse(
        '这段话我想了很久，一直没想明白到底是什么意思 https://x.cn/1',
      );
      expect(r.body, '这段话我想了很久，一直没想明白到底是什么意思');
      expect(r.isExcerpt, isTrue);
    });

    // 书名在正文里被提到，不该因此把整行当成指路而丢掉。
    test('正文里提到书名，正文照留', () {
      final r = SharedReading.parse('《百年孤独》开头那一句真的是神来之笔，我读了三遍');
      expect(r.bookTitle, '百年孤独');
      expect(r.isExcerpt, isTrue);
      expect(r.body, contains('神来之笔'));
    });
  });

  group('不要误伤', () {
    test('空字符串', () {
      expect(SharedReading.parse('').isEmpty, isTrue);
      expect(SharedReading.parse('   \n  \n ').isEmpty, isTrue);
    });

    // 「一起看」这类词出现在正文里会误杀。这是已知取舍：宁可漏掉一句
    // 带推广词的原文，也不要把推广语当成摘录存进他的收藏。
    // 记在这儿，是为了将来有人报「我的摘录丢了」时能一眼看到原因。
    test('已知取舍：正文含推广词会被当成推广语丢掉', () {
      final r = SharedReading.parse('这本书真好，推荐给你');
      expect(r.body, isEmpty);
    });
  });

  _clipboardShapes();
}

/// 剪贴板那条路的样本。
///
/// 番茄的分享面板是自己画的，没有「系统分享」——`ACTION_SEND` 够不着它。
/// 但它有「复制」，所以真正会走到解析这一步的，是从剪贴板粘进来的东西。
/// 下面这些是各家「复制」出来的形状。
void _clipboardShapes() {
  group('从剪贴板粘进来', () {
    test('番茄：正文 + 出处 + 落款', () {
      final r = SharedReading.parse(
        '那年春天，我十六岁。在一个阳光明媚的下午，我上完周六的课。\n'
        '——《植物妻子》\n'
        '来自番茄小说',
      );
      expect(r.bookTitle, '植物妻子');
      expect(r.body, '那年春天，我十六岁。在一个阳光明媚的下午，我上完周六的课。');
    });

    test('番茄：正文 + 复制打开 APP 的尾巴', () {
      final r = SharedReading.parse(
        '直到天黑，我仍旧对着操场发呆，什么也没做，什么也没想。\n'
        '链接：https://fanqienovel.com/x 复制打开番茄小说APP',
      );
      expect(r.body, '直到天黑，我仍旧对着操场发呆，什么也没做，什么也没想。');
      expect(r.isExcerpt, isTrue);
    });

    test('落款只在短行才算，正文里提到番茄不受影响', () {
      final r = SharedReading.parse(
        '番茄小说里这一段我读了三遍，每次都觉得那个下午长得不像话',
      );
      expect(r.body, contains('读了三遍'));
      expect(r.isExcerpt, isTrue);
    });

    test('光复制了个书名', () {
      final r = SharedReading.parse('植物妻子');
      expect(r.bookTitle, '植物妻子');
      expect(r.isExcerpt, isFalse);
    });
  });
}
