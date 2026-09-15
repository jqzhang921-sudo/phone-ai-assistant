import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/config/api_keys.dart';
import 'package:phone_ai_assistant/services/ai_client.dart';
import 'package:phone_ai_assistant/services/chat_images.dart';
import 'package:phone_ai_assistant/services/nudge_service.dart';
import 'package:phone_ai_assistant/services/phone_tools/self_note_tool.dart';
import 'package:phone_ai_assistant/services/screen_glance.dart';
import 'package:phone_ai_assistant/services/self_notes.dart';

/// 「过会儿看一眼」的便签：它在聊天里特意要了才看，普通便签照旧不看。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SelfNoteTool.currentConversationId = null;
  });

  group('便签存得住「到点先看一眼」', () {
    final base = SelfNote(
      id: 'n1',
      conversationId: 'c1',
      about: 'TA 说再刷十分钟就睡',
      createdAt: DateTime(2026, 9, 15, 23),
      dueAt: DateTime(2026, 9, 15, 23, 10),
    );

    test('普通便签不写这个字段', () {
      expect(base.toJson().containsKey('glance'), isFalse);
      expect(SelfNote.fromJson(base.toJson())!.glance, isFalse);
    });

    test('要看的便签来回存取还是要看', () {
      final n = SelfNote(
        id: base.id,
        conversationId: base.conversationId,
        about: base.about,
        createdAt: base.createdAt,
        dueAt: base.dueAt,
        glance: true,
      );
      expect(SelfNote.fromJson(n.toJson())!.glance, isTrue);
    });
  });

  group('follow_up_later 的 look_at_screen', () {
    Future<Map<String, dynamic>> leave({bool look = true}) =>
        SelfNoteTool.execute({
          'about': 'TA 说再刷十分钟就睡',
          'after_minutes': 10,
          if (look) 'look_at_screen': true,
        });

    test('她允许看屏幕：记成要看的便签，也告诉它到点会先看', () async {
      await ScreenGlance.setAllowed(true);
      final r = await leave();
      expect(r['success'], isTrue);
      expect(r['message'], contains('先看一眼'));
      expect((await SelfNoteStore.list()).single.glance, isTrue);
    });

    test('她没允许：照样记下，但记成普通便签，并且明说不会看', () async {
      final r = await leave();
      expect(r['success'], isTrue);
      expect(r['message'], contains('没开'));
      expect((await SelfNoteStore.list()).single.glance, isFalse);
    });

    test('没要看就是普通便签', () async {
      await ScreenGlance.setAllowed(true);
      await leave(look: false);
      expect((await SelfNoteStore.list()).single.glance, isFalse);
    });
  });

  test('到点的「要看」便签，候选上也带着要看', () async {
    final now = DateTime.now();
    await SelfNoteStore.add(
      SelfNote(
        id: 'due',
        conversationId: 'c1',
        about: 'TA 说再刷十分钟就睡',
        createdAt: now.subtract(const Duration(minutes: 15)),
        dueAt: now.subtract(const Duration(minutes: 5)),
        glance: true,
      ),
    );
    final picked = (await NudgeService.collectCandidates()).firstWhere(
      (c) => c.noteId == 'due',
    );
    expect(picked.glance, isTrue);
    expect(picked.conversationId, 'c1');
  });

  test('便签到点那一看：prompt 里接的是便签上那件事', () async {
    final tmp = await Directory.systemTemp.createTemp('note_glance');
    ChatImages.dirPath = tmp.path;
    final defaultClient = AiClient.newHttpClient;
    final bodies = <Map<String, dynamic>>[];
    AiClient.newHttpClient =
        () => MockClient.streaming((request, body) async {
          bodies.add(
            jsonDecode(utf8.decode(await body.toBytes()))
                as Map<String, dynamic>,
          );
          final sse = [
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': '说好的十分钟呢'},
                },
              ],
            })}',
            'data: [DONE]',
            '',
          ].join('\n');
          return http.StreamedResponse(Stream.value(utf8.encode(sse)), 200);
        });

    try {
      final webp = [82, 73, 70, 70, 0, 0, 0, 0, 87, 69, 66, 80];
      final ref = await ChatImages.save(webp);
      final out = await NudgeService.composeFromGlance(
        aiClient: AiClient(
          config: ApiKeyConfig(
            provider: 'openai',
            name: 'openai',
            endpoint: 'https://example.invalid/v1',
            model: 'm',
            apiKey: 'k',
          ),
        ),
        image: ref,
        bytes: webp,
        app: '小红书',
        note: 'TA 说再刷十分钟就睡',
      );
      expect(out, '说好的十分钟呢');

      final prompt = jsonEncode(bodies.single['messages']);
      expect(prompt, contains('再刷十分钟就睡'));
      expect(prompt, contains('便签'));
      expect(prompt, contains('小红书'));
      expect(prompt, contains('data:image/webp;base64,'));
    } finally {
      AiClient.newHttpClient = defaultClient;
      ChatImages.dirPath = null;
      await tmp.delete(recursive: true);
    }
  });
}
