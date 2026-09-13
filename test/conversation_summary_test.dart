import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/models/conversation.dart';
import 'package:phone_ai_assistant/models/conversation_summary.dart';

ChatMessage _msg(
  MessageRole role,
  String content, {
  List<String> images = const [],
}) => ChatMessage(
  id: 'm${content.hashCode}',
  role: role,
  content: content,
  timestamp: DateTime(2026, 9, 14, 10),
  images: images,
);

Conversation _conv(List<ChatMessage> messages, {String title = '聊点什么'}) {
  final c = Conversation(id: 'c1', title: title, messages: messages);
  return c;
}

void main() {
  group('索引：只留正文，不留图片', () {
    test('图片一个字节都不进索引——这是这层存在的全部理由', () {
      final conv = _conv([
        _msg(MessageRole.user, '这是什么', images: ['A' * 5000, 'B' * 5000]),
        _msg(MessageRole.assistant, '是一只猫'),
      ]);

      final json = ConversationSummary.fromConversation(conv).toJson();
      final encoded = json.toString();

      expect(encoded.contains('A' * 100), isFalse);
      expect(encoded.contains('B' * 100), isFalse);
      // 正文还在，一个字都不能少——搜索靠它。
      expect(encoded.contains('这是什么'), isTrue);
      expect(encoded.contains('是一只猫'), isTrue);
    });

    test('条数是总数，含工具消息；正文里没有工具消息', () {
      final conv = _conv([
        _msg(MessageRole.user, '看看天气'),
        _msg(MessageRole.toolCall, '{"name":"weather"}'),
        _msg(MessageRole.toolResult, '{"temp":21}'),
        _msg(MessageRole.assistant, '21 度'),
      ]);

      final s = ConversationSummary.fromConversation(conv);

      expect(s.messageCount, 4, reason: '界面上写的「N 条消息」一直是总数');
      expect(s.lines.map((l) => l.content), ['看看天气', '21 度']);
    });

    test('留下的下标是原下标，不是剔完之后的序号', () {
      // 工具消息被跳过后，后面那些的下标整体错位——错位就会滚错地方。
      final conv = _conv([
        _msg(MessageRole.toolCall, 't0'),
        _msg(MessageRole.user, '第二句'),
        _msg(MessageRole.toolResult, 't2'),
        _msg(MessageRole.toolCall, 't3'),
        _msg(MessageRole.assistant, '第五句'),
      ]);

      final s = ConversationSummary.fromConversation(conv);

      expect(s.lines.map((l) => l.index), [1, 4]);
      expect(s.lines.first.content, '第二句');
      expect(s.lines.last.content, '第五句');
    });

    test('元数据原样带过去，列表要靠它排和显示', () {
      final c = _conv([_msg(MessageRole.user, '嗨')]);
      c.updatedAt = DateTime(2026, 9, 13, 8);
      c.isPinned = true;
      c.model = 'deepseek-v4-pro';

      final s = ConversationSummary.fromConversation(c);

      expect(s.id, 'c1');
      expect(s.title, '聊点什么');
      expect(s.updatedAt, DateTime(2026, 9, 13, 8));
      expect(s.isPinned, isTrue);
      expect(s.model, 'deepseek-v4-pro');
    });

    test('空对话也能压出索引，不是 null', () {
      final s = ConversationSummary.fromConversation(_conv([]));
      expect(s.messageCount, 0);
      expect(s.lines, isEmpty);
    });

    test('人格只留一个布尔值，正文一个字都不抄', () {
      final c = _conv([_msg(MessageRole.user, '嗨')]);
      c.systemPrompt = '你是一只脾气很差的猫，说话不超过十个字。';

      final s = ConversationSummary.fromConversation(c);

      expect(s.hasSystemPrompt, isTrue);
      expect(
        s.toJson().toString().contains('脾气很差'),
        isFalse,
        reason: '这层只回答「有没有设过人格」，不负责把那份人格也复制一份——'
            '设置页要的只是个条数',
      );
    });

    test('没设过、设成空串，都算没有', () {
      // null 和 '' 在别处被当成同一件事（`(systemPrompt ?? '').isNotEmpty`），
      // 索引也得跟那个判断一致，否则设置页那个条数会多出来。
      expect(
        ConversationSummary.fromConversation(
          _conv([_msg(MessageRole.user, '嗨')]),
        ).hasSystemPrompt,
        isFalse,
      );

      final blank = _conv([_msg(MessageRole.user, '嗨')]);
      blank.systemPrompt = '';
      expect(
        ConversationSummary.fromConversation(blank).hasSystemPrompt,
        isFalse,
      );
    });
  });

  group('索引：落盘再读回来', () {
    test('原样往返', () {
      final conv = _conv([
        _msg(MessageRole.user, '第一句\n带换行'),
        _msg(MessageRole.toolCall, '跳过的'),
        _msg(MessageRole.assistant, '第二句 "带引号" \\ 带反斜杠'),
      ]);
      final before = ConversationSummary.fromConversation(conv);

      final after = ConversationSummary.fromJson(before.toJson());

      expect(after.id, before.id);
      expect(after.title, before.title);
      expect(after.messageCount, before.messageCount);
      expect(after.updatedAt, before.updatedAt);
      expect(after.model, before.model);
      expect(after.isPinned, before.isPinned);
      expect(after.lines.map((l) => l.index), before.lines.map((l) => l.index));
      expect(after.lines.map((l) => l.role), before.lines.map((l) => l.role));
      expect(
        after.lines.map((l) => l.content),
        before.lines.map((l) => l.content),
        reason: '换行、引号、反斜杠都得原样回来——搜索是按原文匹配的',
      );
    });

    test('格式版本对不上就抛，让调用方从正文重建', () {
      final json =
          ConversationSummary.fromConversation(
            _conv([_msg(MessageRole.user, '嗨')]),
          ).toJson();

      // 换个版本号，模拟「改了形状的老索引」。
      json['v'] = ConversationSummary.formatVersion + 1;

      expect(
        () => ConversationSummary.fromJson(json),
        throwsA(isA<FormatException>()),
        reason: '宁可重建，也不要把字段含义已经变了的旧索引当成对的用',
      );
    });

    test('v 字段缺了也算对不上', () {
      final json =
          ConversationSummary.fromConversation(
            _conv([_msg(MessageRole.user, '嗨')]),
          ).toJson();
      json.remove('v');

      expect(
        () => ConversationSummary.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
