import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/book_lookup.dart';

/// 微信读书返回的形状（只留用得上的字段）。
Map<String, dynamic> _book({
  required String title,
  String author = '',
  String publisher = '',
  String intro = '',
}) => {
  'bookInfo': {
    'title': title,
    'author': author,
    'publisher': publisher,
    'intro': intro,
  },
};

void main() {
  // 2026-09-07 真实的那一次：用户说《金枝玉叶》，作者余耕。
  final jinzhi = _book(
    title: '金枝玉叶',
    author: '余耕',
    publisher: '百花文艺出版社',
    intro: '金枝的母亲是第一批上山下乡的知青⋯⋯',
  );

  group('挑对那一本', () {
    test('书名作者都对上，算确认过', () {
      final f = BookLookup.pick([jinzhi], title: '金枝玉叶', author: '余耕');
      expect(f, isNotNull);
      expect(f!.confirmed, isTrue);
      expect(f.publisher, '百花文艺出版社');
      expect(f.intro, contains('知青'));
    });

    test('书名带书名号也能对上', () {
      final f = BookLookup.pick([jinzhi], title: '《金枝玉叶》', author: '余耕');
      expect(f?.confirmed, isTrue);
    });

    test('书库里作者写成「余耕 著」，双向包含也算对上', () {
      final f = BookLookup.pick([
        _book(title: '金枝玉叶', author: '余耕 著'),
      ], title: '金枝玉叶', author: '余耕');
      expect(f?.confirmed, isTrue);
    });

    // 搜「金枝玉叶」回来一堆同名的，得挑作者对的那一条，不能拿第一条。
    test('同名多本时按作者挑，不取第一条', () {
      final f = BookLookup.pick([
        _book(title: '金枝玉叶', author: '亦舒'),
        _book(title: '金枝玉叶', author: '张爱玲'),
        jinzhi,
      ], title: '金枝玉叶', author: '余耕');
      expect(f?.author, '余耕');
    });
  });

  group('宁可什么都不给', () {
    // 这是整个文件里最重要的一条。给错一本书的资料，AI 会拿着别人的情节
    // 跟他讨论，而他**根本不知道 AI 手里拿的是另一本**——比空着手糟得多。
    test('作者对不上就返回 null，不退而求其次', () {
      final f = BookLookup.pick([
        _book(title: '金枝玉叶', author: '亦舒'),
      ], title: '金枝玉叶', author: '余耕');
      expect(f, isNull);
    });

    test('书名对不上就没有——不做模糊匹配', () {
      final f = BookLookup.pick([
        _book(title: '金枝玉叶传', author: '余耕'),
      ], title: '金枝玉叶', author: '余耕');
      expect(f, isNull);
    });

    test('空结果 / 结构不对 / null，都不抛', () {
      expect(BookLookup.pick([], title: '金枝玉叶'), isNull);
      expect(BookLookup.pick(null, title: '金枝玉叶'), isNull);
      expect(BookLookup.pick('不是数组', title: '金枝玉叶'), isNull);
      expect(BookLookup.pick([1, 2, {}], title: '金枝玉叶'), isNull);
      expect(BookLookup.pick([jinzhi], title: '  '), isNull);
    });
  });

  group('没说作者的时候', () {
    // 首页「说本书」只问书名，所以这条路很常走。
    test('取第一条，但标成未确认', () {
      final f = BookLookup.pick([jinzhi], title: '金枝玉叶');
      expect(f, isNotNull);
      expect(f!.confirmed, isFalse);
    });

    test('未确认时提示词里要有「先确认一句」', () {
      final block = BookLookup.pick([jinzhi], title: '金枝玉叶')!.asPromptBlock();
      expect(block, contains('确认'));
      expect(block, contains('余耕'));
    });
  });

  group('拼进提示词的那一段', () {
    late String block;
    setUp(() {
      block =
          BookLookup.pick([jinzhi], title: '金枝玉叶', author: '余耕')!
              .asPromptBlock();
    });

    // 这三条是这个功能的安全带。少一条，「让它知道点东西」就会变成
    // 「让它装作读过」——那比什么都不知道更伤。
    test('写明这不等于读过', () {
      expect(block, contains('不等于你读过'));
    });

    test('写明照实说没读过', () {
      expect(block, contains('照实说没读过'));
    });

    test('写明对不上以用户为准', () {
      expect(block, contains('以用户为准'));
    });

    test('确认过的那本不再要求「先问一句」', () {
      expect(block, isNot(contains('先用一句话确认')));
    });

    test('资料本身都在里面', () {
      expect(block, contains('金枝玉叶'));
      expect(block, contains('余耕'));
      expect(block, contains('百花文艺出版社'));
      expect(block, contains('知青'));
    });

    test('没查到划线的时候不留一个空标题', () {
      expect(block, isNot(contains('划得最多')));
    });
  });

  group('热门划线', () {
    // 真实形状：章节名单独一个数组，每条划线只带 chapterUid。
    Map<String, dynamic> best({
      List<Map<String, dynamic>>? chapters,
      List<Map<String, dynamic>>? items,
    }) => {
      'totalCount': 232,
      'chapters':
          chapters ??
          [
            {'chapterUid': 3, 'title': '引言'},
            {'chapterUid': 9, 'title': '六、谁是反革命'},
          ],
      'items':
          items ??
          [
            {'chapterUid': 3, 'markText': '人生很短，人生也很长。'},
            {'chapterUid': 9, 'markText': '我举起手，指着柿子树。'},
          ],
    };

    test('把 chapterUid 换成章节名', () {
      final marks = BookLookup.pickHotMarks(best());
      expect(marks.length, 2);
      expect(marks.first.text, '人生很短，人生也很长。');
      expect(marks.first.chapter, '引言');
      expect(marks.last.chapter, '六、谁是反革命');
    });

    // 章节名是附赠的。对不上就不写，但**原句不能跟着丢**——
    // 原句才是这个功能的全部价值。
    test('章节名对不上，原句照样留着', () {
      final marks = BookLookup.pickHotMarks(
        best(
          items: [
            {'chapterUid': 999, 'markText': '孤零零一句'},
          ],
        ),
      );
      expect(marks.single.text, '孤零零一句');
      expect(marks.single.chapter, isNull);
    });

    test('原书的排版空白压掉，空的丢掉', () {
      final marks = BookLookup.pickHotMarks(
        best(
          items: [
            {'chapterUid': 3, 'markText': '  他说\n\n  是我爹  '},
            {'chapterUid': 3, 'markText': '   '},
          ],
        ),
      );
      expect(marks.single.text, '他说 是我爹');
    });

    // 同一句被不同人划成不同长度是常事，回来会是两条几乎一样的。
    test('压缩之后一样的算重复', () {
      final marks = BookLookup.pickHotMarks(
        best(
          items: [
            {'chapterUid': 3, 'markText': '人生很短'},
            {'chapterUid': 9, 'markText': ' 人生很短 '},
          ],
        ),
      );
      expect(marks.length, 1);
    });

    test('最多十条', () {
      final marks = BookLookup.pickHotMarks(
        best(
          items: List.generate(
            30,
            (i) => {'chapterUid': 3, 'markText': '第 $i 句'},
          ),
        ),
      );
      expect(marks.length, 10);
    });

    test('整段的划线截断，不让一条吃掉整段预算', () {
      final marks = BookLookup.pickHotMarks(
        best(
          items: [
            {'chapterUid': 3, 'markText': '啊' * 500},
          ],
        ),
      );
      expect(marks.single.text.length, lessThan(500));
      expect(marks.single.text, endsWith('…'));
    });

    test('结构不对 / 缺字段，都不抛', () {
      expect(BookLookup.pickHotMarks(null), isEmpty);
      expect(BookLookup.pickHotMarks('不是 Map'), isEmpty);
      expect(BookLookup.pickHotMarks(<String, dynamic>{}), isEmpty);
      expect(BookLookup.pickHotMarks({'items': '不是数组'}), isEmpty);
      expect(
        BookLookup.pickHotMarks({
          'chapters': '不是数组',
          'items': [
            {'markText': '还在'},
          ],
        }).single.text,
        '还在',
      );
    });
  });

  group('划线拼进提示词', () {
    late String block;
    setUp(() {
      block =
          BookLookup.pick([jinzhi], title: '金枝玉叶', author: '余耕')!
              .withHotMarks(const [
                HotMark('人生很短，人生也很长。', chapter: '引言'),
                HotMark('没有章节的那一句'),
              ])
              .asPromptBlock();
    });

    test('原句和章节名都写进去', () {
      expect(block, contains('人生很短，人生也很长。'));
      expect(block, contains('（引言）'));
    });

    test('没有章节名的不留一对空括号', () {
      expect(block, contains('- 没有章节的那一句'));
      expect(block, isNot(contains('（）')));
    });

    // 手里有了十句真原文，编第十一句就顺理成章——这条护栏比原来更要紧，
    // 因为它防的是「引得有模有样、但那句书里根本没有」。
    test('写死「原文就只有这几句」', () {
      expect(block, contains('你手上的原文就只有这几句'));
      expect(block, contains('不许再写出第二批'));
    });

    test('原来那几条护栏一条都没少', () {
      expect(block, contains('不等于你读过'));
      expect(block, contains('照实说没读过'));
      expect(block, contains('以用户为准'));
    });

    test('补划线不会把书目资料弄丢', () {
      expect(block, contains('余耕'));
      expect(block, contains('百花文艺出版社'));
    });
  });
}
