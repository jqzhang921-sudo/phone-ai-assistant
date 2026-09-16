import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';

/// 带思考的模型（DeepSeek 系）一旦调过工具，后面每次请求都得把 `reasoning_content`
/// 原样带回去。2026-09-16 Cleo 让它看一眼屏幕，那一轮就断在这条 400 上：
/// `The reasoning_content in the thinking mode must be passed back to the API`。
///
/// 而有的中转站反过来不认这个字段。两个方向的错法完全相反，治错了方向等于没治，
/// 所以这里把「看懂服务端在抱怨什么」钉死。
void main() {
  group('看懂服务端在抱怨什么', () {
    test('DeepSeek 那条原话：要我们带回去', () {
      expect(
        reasoningComplaintOf(
          'The reasoning_content in the thinking mode must be passed back to the API',
        ),
        ReasoningComplaint.mustPass,
      );
    });

    test('中文的「必须」也认', () {
      expect(
        reasoningComplaintOf('思考模式下 reasoning_content 必须原样传回'),
        ReasoningComplaint.mustPass,
      );
    });

    test('不认这个字段：摘掉', () {
      for (final e in [
        'Unknown parameter: messages[3].reasoning_content',
        'unsupported field reasoning_content',
        "Invalid value for 'reasoning_content'",
      ]) {
        expect(
          reasoningComplaintOf(e),
          ReasoningComplaint.notAllowed,
          reason: e,
        );
      }
    });

    test('跟这个字段无关的错，一概不管', () {
      for (final e in [
        '{"error":{"code":"500","message":"Internal Server Error"}}',
        'tool_call_id not found',
        '',
      ]) {
        expect(reasoningComplaintOf(e), ReasoningComplaint.none, reason: e);
      }
    });

    test('提到了这个字段但看不出是哪一种：当成它不认', () {
      // 少发一个字段顶多丢一点思路；多发一个可能整条请求发不出去。
      expect(
        reasoningComplaintOf('reasoning_content 有问题'),
        ReasoningComplaint.notAllowed,
      );
    });
  });

  group('两个方向的改法', () {
    final msgs = <Map<String, dynamic>>[
      {'role': 'system', 'content': '人设'},
      {'role': 'user', 'content': '你看看'},
      {
        'role': 'assistant',
        'content': null,
        'reasoning_content': '她让我看屏幕',
        'tool_calls': [
          {'id': 'c1'},
        ],
      },
      {'role': 'tool', 'tool_call_id': 'c1', 'content': '{}'},
      {'role': 'assistant', 'content': '看到了'},
    ];

    test('摘掉：一条都不剩，别的字段不动', () {
      final out = stripReasoning(msgs);
      expect(out.any((m) => m.containsKey('reasoning_content')), isFalse);
      expect(out[2]['tool_calls'], isNotNull);
      expect(out[1]['content'], '你看看');
      // 原来那份不能被改掉
      expect(msgs[2]['reasoning_content'], '她让我看屏幕');
    });

    test('补空的：只补 assistant，已有的不覆盖', () {
      final out = fillMissingReasoning(msgs);
      expect(out[2]['reasoning_content'], '她让我看屏幕'); // 有就不动
      expect(out[4]['reasoning_content'], ''); // 缺的补空
      expect(out[1].containsKey('reasoning_content'), isFalse); // user 不碰
      expect(out[3].containsKey('reasoning_content'), isFalse); // tool 不碰
    });

    test('补过之后就不再缺，摘过之后就一条都没有——所以重试只会发生一次', () {
      final filled = fillMissingReasoning(msgs);
      expect(
        filled.any(
          (m) => m['role'] == 'assistant' && m['reasoning_content'] == null,
        ),
        isFalse,
      );
      final stripped = stripReasoning(msgs);
      expect(stripped.any((m) => m['reasoning_content'] != null), isFalse);
    });
  });
}
