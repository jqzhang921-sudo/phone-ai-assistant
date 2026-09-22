import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';

/// 2026-09-22 Cleo：「以前……当时她就是自己按需思考，现在可能因为模型更新了
/// 所以每次都会思考？」——是默认值变了。DeepSeek 的 thinking 三档
/// （enabled / disabled / adaptive）默认 enabled，adaptive 才是按需。
void main() {
  group('认不认得出是 DeepSeek', () {
    test('官方地址和模型名都认得', () {
      expect(looksLikeDeepSeek(endpoint: 'https://api.deepseek.com/v1'), isTrue);
      expect(looksLikeDeepSeek(model: 'deepseek-v4-pro'), isTrue);
      expect(looksLikeDeepSeek(model: 'deepseek-chat'), isTrue);
    });

    test('别家一律不认——宁可漏，不可错', () {
      // ⚠️ 漏认只是继续每次都思考；认错可能让整条请求被拒。
      expect(looksLikeDeepSeek(endpoint: 'https://api.openai.com/v1'), isFalse);
      expect(looksLikeDeepSeek(model: 'gpt-4o'), isFalse);
      expect(looksLikeDeepSeek(), isFalse);
    });

    test('模型名里带 deepseek 但不是开头的，不认', () {
      // 中转站常把名字拼成「xx-deepseek-yy」，那多半不是官方端点。
      expect(looksLikeDeepSeek(model: 'proxy-deepseek-v4'), isFalse);
    });
  });

  group('端点不认这个字段时', () {
    test('认得出这是在抱怨 thinking', () {
      expect(thinkingComplaint('Unknown parameter: thinking'), isTrue);
      expect(thinkingComplaint('unsupported field "thinking"'), isTrue);
      expect(thinkingComplaint('不支持 thinking 参数'), isTrue);
    });

    test('跟 thinking 无关的错，别乱动', () {
      expect(thinkingComplaint('rate limit exceeded'), isFalse);
      expect(thinkingComplaint('tool_call_id not found'), isFalse);
    });

    test('提到 thinking 但不是「不认识」那类，不去掉', () {
      // 比如它抱怨的是 reasoning_content 该回传，那是另一回事。
      expect(
        thinkingComplaint('The reasoning_content in the thinking mode must be passed back'),
        isFalse,
      );
    });
  });
}
