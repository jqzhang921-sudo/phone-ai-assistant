import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';

/// 连接「不断也不回」时，必须报错收场，不能一直转圈。
///
/// 2026-09-14 读书讨论《窄门》：发出去之后进度条一直走、发送键灰着、没有任何
/// 报错——请求没有超时，卡住的连接就等到天荒地老。
void main() {
  final defaults = (
    response: AiClient.responseTimeout,
    idle: AiClient.idleTimeout,
    client: AiClient.newHttpClient,
  );

  setUp(() {
    AiClient.responseTimeout = const Duration(milliseconds: 80);
    AiClient.idleTimeout = const Duration(milliseconds: 80);
  });

  tearDown(() {
    AiClient.responseTimeout = defaults.response;
    AiClient.idleTimeout = defaults.idle;
    AiClient.newHttpClient = defaults.client;
  });

  final hello = [ChatMessage(id: 'u', role: MessageRole.user, content: '在吗')];

  AiClient clientOf(String provider) => AiClient(
    config: ApiKeyConfig(
      provider: provider,
      name: provider,
      endpoint: 'https://example.invalid/v1',
      model: 'm',
      apiKey: 'k',
    ),
  );

  Future<AiStreamEvent> lastEvent(AiClient c) =>
      c.chat(hello).last.timeout(const Duration(seconds: 5));

  for (final provider in ['custom', 'anthropic']) {
    group(provider, () {
      test('响应头一直不来：超时报错', () async {
        AiClient.newHttpClient =
            () => MockClient.streaming(
              (request, body) => Completer<http.StreamedResponse>().future,
            );

        final event = await lastEvent(clientOf(provider));
        expect(event.type, AiEventType.error);
        expect(event.error, contains('超时'));
      });

      test('流开了头就没动静：超时报错', () async {
        AiClient.newHttpClient =
            () => MockClient.streaming((request, body) async {
              final stuck = StreamController<List<int>>();
              return http.StreamedResponse(stuck.stream, 200);
            });

        final event = await lastEvent(clientOf(provider));
        expect(event.type, AiEventType.error);
        expect(event.error, contains('超时'));
      });
    });
  }

  test('正常回话不受影响', () async {
    AiClient.newHttpClient =
        () => MockClient.streaming((request, body) async {
          final sse = [
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '在'},
                },
              ],
            })}',
            'data: [DONE]',
            '',
          ].join('\n');
          return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
        });

    final event = await lastEvent(clientOf('custom'));
    expect(event.type, AiEventType.done);
    expect(event.text, '在');
  });
}
