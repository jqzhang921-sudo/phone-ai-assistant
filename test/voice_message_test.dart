import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/voice_message.dart';
import 'package:phone_ai_assistant/services/phone_tools/voice_tool.dart';

void main() {
  group('从 metadata 里认出语音', () {
    test('正常的一条', () {
      final v = VoiceMessage.fromMetadata({
        'voice': {'path': '/data/voice/a.mp3', 'seconds': 7},
      });
      expect(v, isNotNull);
      expect(v!.path, '/data/voice/a.mp3');
      expect(v.seconds, 7);
    });

    // 时长拿不到不该让整条语音发不出去，界面显示 `--` 就行。
    test('没有时长也算数', () {
      final v = VoiceMessage.fromMetadata({
        'voice': {'path': '/data/voice/a.mp3'},
      });
      expect(v, isNotNull);
      expect(v!.seconds, isNull);
    });

    test('不是语音消息就返回 null', () {
      expect(VoiceMessage.fromMetadata(null), isNull);
      expect(VoiceMessage.fromMetadata({}), isNull);
      expect(VoiceMessage.fromMetadata({'nudge': true}), isNull);
    });

    // 结构坏掉的（老版本、手改过的 JSON）不能抛——聊天记录是用户
    // 最不能丢的东西，一条读不出来不该让整段打不开。
    test('结构坏掉的不抛，返回 null', () {
      expect(VoiceMessage.fromMetadata({'voice': '不是对象'}), isNull);
      expect(VoiceMessage.fromMetadata({'voice': {}}), isNull);
      expect(VoiceMessage.fromMetadata({'voice': {'path': ''}}), isNull);
      expect(VoiceMessage.fromMetadata({'voice': {'path': 123}}), isNull);
    });

    test('存下来再读回去是同一条', () {
      const v = VoiceMessage(path: '/a/b.mp3', seconds: 3);
      expect(VoiceMessage.fromMetadata({'voice': v.toJson()})!.path, '/a/b.mp3');
    });
  });

  group('send_voice 的护栏', () {
    test('空文本直接挡回去', () async {
      final r = await VoiceTool.execute({'text': '  '});
      expect(r['success'], isFalse);
    });

    // 一条两分钟的语音没人听得完，钱还照花。
    test('太长的挡回去，并说清楚多少字', () async {
      final r = await VoiceTool.execute({'text': '啊' * 300});
      expect(r['success'], isFalse);
      expect(r['error'], contains('300'));
    });

    test('工具描述里写明了只会显示成语音条', () {
      final d = VoiceTool.definition.description;
      expect(d, contains('看不到文字'));
      expect(d, contains('长按'));
      // 失败要能退回文字，不能让这句话没说出口
      expect(d, contains('照常用文字'));
    });
  });
}
