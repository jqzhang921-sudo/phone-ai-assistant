import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/services/nudge_gate.dart';
import 'package:phone_ai_assistant/services/nudge_service.dart';

/// 好久没说话时它看一眼屏幕：什么时候问、问的时候给了什么、看完怎么收场。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final defaultClient = AiClient.newHttpClient;
  late List<Map<String, dynamic>> bodies;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bodies = [];
  });

  tearDown(() => AiClient.newHttpClient = defaultClient);

  /// 模型那边：把请求体记下来，按 [chunks] 回一段流。
  void serve(List<Map<String, dynamic>> chunks, {int status = 200}) {
    AiClient.newHttpClient =
        () => MockClient.streaming((request, body) async {
          bodies.add(
            jsonDecode(utf8.decode(await body.toBytes()))
                as Map<String, dynamic>,
          );
          if (status != 200) {
            return http.StreamedResponse(
              Stream.value(utf8.encode('boom')),
              status,
            );
          }
          final sse = [
            for (final c in chunks) 'data: ${jsonEncode(c)}',
            'data: [DONE]',
            '',
          ].join('\n');
          return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
        });
  }

  Map<String, dynamic> says(String text) => {
    'choices': [
      {
        'delta': {'content': text},
      },
    ],
  };

  AiClient clientOf([String provider = 'custom']) => AiClient(
    config: ApiKeyConfig(
      provider: provider,
      name: provider,
      endpoint: 'https://example.invalid/v1',
      model: 'm',
      apiKey: 'k',
    ),
  );

  group('什么时候才问它想不想看', () {
    final now = DateTime(2026, 9, 15, 16);

    test('刚聊完不问', () {
      expect(
        glanceDue(now: now, lastChatAt: now.subtract(const Duration(hours: 2))),
        isFalse,
      );
    });

    test('安静够久了才问', () {
      expect(
        glanceDue(now: now, lastChatAt: now.subtract(const Duration(hours: 4))),
        isTrue,
      );
    });

    test('上次问过没多久不再问——不管上次看没看成', () {
      expect(
        glanceDue(
          now: now,
          lastChatAt: now.subtract(const Duration(hours: 8)),
          lastAskedAt: now.subtract(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('从来没聊过、从来没问过：可以问', () {
      expect(glanceDue(now: now), isTrue);
    });
  });

  test('看了没说话的那条不发给模型；说了话的那条照常发', () async {
    serve([says('嗯')]);
    await clientOf().chat([
      ChatMessage(id: 'u1', role: MessageRole.user, content: '我去忙了'),
      ChatMessage(
        id: 'g1',
        role: MessageRole.assistant,
        content: '',
        images: const ['file:a.img'],
        metadata: const {'glance': true},
      ),
      ChatMessage(
        id: 'g2',
        role: MessageRole.assistant,
        content: '那本书的封面我也记得',
        images: const ['file:b.img'],
        metadata: const {'glance': true, 'nudge': true},
      ),
      ChatMessage(id: 'u2', role: MessageRole.user, content: '回来啦'),
    ]).last;

    final sent = bodies.single['messages'] as List;
    final assistants = sent.where((m) => m['role'] == 'assistant').toList();
    expect(assistants, hasLength(1));
    expect('${assistants.single['content']}', contains('那本书的封面'));
  });

  group('第一问：想不想看', () {
    test('调了 glance_screen 就是想看；手上只给了这一个工具', () async {
      serve([
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'type': 'function',
                    'function': {'name': 'glance_screen', 'arguments': '{}'},
                  },
                ],
              },
            },
          ],
        },
      ]);

      final wants = await NudgeService.wantsToGlance(
        aiClient: clientOf(),
        silence: const Duration(hours: 4),
        app: '小红书',
      );
      expect(wants, isTrue);

      final body = bodies.single;
      expect(body['tools'], hasLength(1));
      expect(jsonEncode(body['tools']), contains('glance_screen'));
      final prompt = jsonEncode(body['messages']);
      expect(prompt, contains('4 个小时'));
      expect(prompt, contains('小红书'));
    });

    test('回了字就是不想看', () async {
      serve([says('不说')]);
      expect(await NudgeService.wantsToGlance(aiClient: clientOf()), isFalse);
    });

    test('模型出错往外抛，不当成「不想看」', () async {
      serve(const [], status: 500);
      await expectLater(
        NudgeService.wantsToGlance(aiClient: clientOf()),
        throwsException,
      );
    });
  });

  group('第二问：看到了，说不说', () {
    late Directory tmp;
    final webp = [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80];

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('glance_test');
      ChatImages.dirPath = tmp.path;
    });

    tearDown(() async {
      ChatImages.dirPath = null;
      await tmp.delete(recursive: true);
    });

    test('截图跟着一起发过去；回「不说」就是 null', () async {
      final ref = await ChatImages.save(webp);
      serve([says('不说')]);

      final out = await NudgeService.composeFromGlance(
        aiClient: clientOf('openai'),
        image: ref,
        bytes: webp,
        app: '微信读书',
      );
      expect(out, isNull);

      final user = (bodies.single['messages'] as List).lastWhere(
        (m) => m['role'] == 'user',
      );
      final content = jsonEncode(user['content']);
      expect(content, contains('data:image/webp;base64,'));
      expect(content, contains('微信读书'));
    });

    test('想说的话原样拿回来', () async {
      final ref = await ChatImages.save(webp);
      serve([says('窄门那段我也划过线')]);

      final out = await NudgeService.composeFromGlance(
        aiClient: clientOf('openai'),
        image: ref,
        bytes: webp,
      );
      expect(out, '窄门那段我也划过线');
    });
  });
}
