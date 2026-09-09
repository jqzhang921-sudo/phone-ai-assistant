import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/reader_traces.dart';

void main() {
  group('合并他自己留下的东西', () {
    // 第三页「一键导入微信读书划线」存的摘录，和接口拉回来的划线是同一批
    // 句子。不去重的话每条出现两遍——白烧一倍 token，还让模型以为这句他
    // 划了两次、格外在意。
    test('接口划线和导入的摘录是同一批，只算一次', () {
      final t = ReaderTraces.build(
        wereadHighlights: ['人生很短，人生也很长。'],
        localQuotes: ['人生很短，人生也很长。'],
      );
      expect(t.highlights, ['人生很短，人生也很长。']);
      expect(t.highlightTotal, 1);
    });

    test('换行和缩进不算差别', () {
      final t = ReaderTraces.build(
        wereadHighlights: ['他说：\n  「是我爹！」'],
        localQuotes: ['他说： 「是我爹！」'],
      );
      expect(t.highlights.length, 1);
    });

    test('空白条目直接丢掉，不占位子', () {
      final t = ReaderTraces.build(
        wereadHighlights: ['  ', '', '\n', '真的有一条'],
      );
      expect(t.highlights, ['真的有一条']);
    });
  });

  group('预算', () {
    // 划得多的书有几百条。全塞进 system prompt 会挤掉人设和历史，
    // 而且 systemPrompt 一变 DeepSeek 的 KV cache 整段作废。
    test('划线超过上限就截断，但要记住原本有多少条', () {
      final many = List.generate(200, (i) => '第 $i 句划线');
      final t = ReaderTraces.build(wereadHighlights: many);
      expect(t.highlights.length, lessThan(200));
      expect(t.highlightTotal, 200);
      expect(t.asPromptBlock(), contains('一共 200 条'));
    });

    test('单条过长的截断，不让一条吃掉整个预算', () {
      final t = ReaderTraces.build(wereadHighlights: ['啊' * 900]);
      expect(t.highlights.single.length, lessThan(900));
      expect(t.highlights.single, endsWith('…'));
    });

    // 这条是这个文件里最要紧的一条。他自己写的想法是**他的判断**，
    // 划线只是他停下来的地方——预算不够的时候先保谁，差别很大。
    test('划线再多也挤不掉他自己写的想法', () {
      final t = ReaderTraces.build(
        wereadHighlights: List.generate(500, (i) => '第 $i 句划线'),
        wereadThoughts: ['这本书让我想起我妈。'],
        localEssays: ['读完那天下了雨。'],
      );
      expect(t.thoughts, ['这本书让我想起我妈。']);
      expect(t.essays, ['读完那天下了雨。']);
    });
  });

  group('拼进提示词的那一段', () {
    test('什么都没有就返回 null，不留一段空壳', () {
      expect(ReaderTraces.build().asPromptBlock(), isNull);
      expect(const ReaderTraces().isEmpty, isTrue);
    });

    test('三类材料都在里面，各自有标题', () {
      final block =
          ReaderTraces.build(
            wereadHighlights: ['划的那句'],
            wereadThoughts: ['写的那条想法'],
            localEssays: ['随笔里那段'],
          ).asPromptBlock()!;
      expect(block, contains('划的那句'));
      expect(block, contains('写的那条想法'));
      expect(block, contains('随笔里那段'));
    });

    // 这两条是这个功能的安全带。少了它们，「让它看见他划过什么」
    // 就会变成「把他划过的句子念回给他」——看着很懂，一句新东西都没有。
    test('写明不要原样念回去', () {
      final block =
          ReaderTraces.build(wereadHighlights: ['随便一句']).asPromptBlock()!;
      expect(block, contains('别把这些原样念回给他'));
    });

    test('写明划线不代表理由，理由得问', () {
      final block =
          ReaderTraces.build(wereadHighlights: ['随便一句']).asPromptBlock()!;
      expect(block, contains('不说明他为什么停'));
      expect(block, contains('别替他把理由写出来'));
    });

    // 有了他的划线之后，「装读过」比只有简介时更容易——手里有真句子了。
    test('写明这依然不等于读过', () {
      final block =
          ReaderTraces.build(wereadHighlights: ['随便一句']).asPromptBlock()!;
      expect(block, contains('不等于你读过这本书'));
    });

    test('没被截断的时候不要多写一句「一共几条」', () {
      final block =
          ReaderTraces.build(wereadHighlights: ['就这一句']).asPromptBlock()!;
      expect(block, isNot(contains('一共')));
    });
  });
}
