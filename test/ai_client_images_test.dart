import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';

/// 「哪个格式能把图原样发给模型」靠的是 [kImageNativeProviders] 那张**手写**
/// 的表。以前这儿写的是 `provider == 'openai'` 一句死判断，而 `custom` 和
/// default 走的是同一个 `_openaiChat`、同一份报文——OpenAI 兼容又能识图的自定义
/// 端点（Gemini 就是一个）图会被**悄悄丢掉**，模型只看到文字。
///
/// 悄悄丢掉是最难查的一类：没有报错、没有日志，表现就是「模型说它没收到图」。
/// 所以这几条钉住「谁能收、谁不能收」，加新档位时改动这里会立刻红。
void main() {
  AiClient clientOf(String provider) =>
      AiClient(config: ApiKeyConfig(provider: provider, name: provider));

  test('能收图的格式：图随报文原样发过去', () {
    for (final p in ['openai', 'gemini']) {
      expect(clientOf(p).sendsImagesNatively, isTrue, reason: p);
    }
  });

  test('不能收图的格式：图得先送去转成文字', () {
    // anthropic 这一档目前也收不了——`_anthropicChat` 根本没构造图片块，
    // 它那条路是不导图的。所以它跟 mimo、custom 一样落在这边。
    for (final p in ['mimo', 'custom', 'anthropic']) {
      expect(clientOf(p).sendsImagesNatively, isFalse, reason: p);
    }
  });

  test('表里的名字都得是真有的档位', () {
    final builtin = ApiKeyConfig.defaults.map((d) => d.provider).toSet();
    // 防手滑：写出 `{'openai', 'gpt-5'}` 这种，这条会立刻红。
    for (final p in kImageNativeProviders) {
      expect(builtin, contains(p), reason: '$p 不在内置档位里');
    }
  });
}
