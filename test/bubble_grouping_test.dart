import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/widgets/chat_message_item.dart';
import 'package:phone_ai_assistant/widgets/message_bubble.dart';

ChatMessage _m(
  MessageRole role,
  String content, {
  required String id,
  int minute = 0,
}) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime(2026, 9, 7, 21, minute),
);

/// 直接问渲染层：第 i 条的分组标记是什么。
///
/// 不起 widget 测试是因为要断言的是**判断**，不是像素。这一层拿到的
/// isGroupStart / isGroupEnd 决定了间距、尖角、头像和操作行，
/// 判断对了，样式就对了。
List<({bool start, bool end})> _flags(List<ChatMessage> messages) {
  final items = groupChatItems(messages, splitBubbles: false);
  return [
    for (var i = 0; i < items.length; i++)
      () {
        final w = chatDisplayItem(items, i);
        final bubble = w is MessageBubble ? w : (w as Column).children.last as MessageBubble;
        return (start: bubble.isGroupStart, end: bubble.isGroupEnd);
      }(),
  ];
}

void main() {
  test('一条自己成一组：既是头也是尾', () {
    final f = _flags([_m(MessageRole.user, '在', id: 'a')]);
    expect(f.single.start, isTrue);
    expect(f.single.end, isTrue);
  });

  // 这是这个功能存在的理由：拆气泡分出来的几段共用一个基础 id，
  // 必须读成「一口气说的三句」，不是三次发言。
  test('拆气泡分出来的几段是同一组', () {
    final f = _flags([
      _m(MessageRole.assistant, '一', id: 'x'),
      _m(MessageRole.assistant, '二', id: 'x#1'),
      _m(MessageRole.assistant, '三', id: 'x#2'),
    ]);
    expect(f.map((e) => e.start).toList(), [true, false, false]);
    expect(f.map((e) => e.end).toList(), [false, false, true]);
  });

  test('换人说话就断组', () {
    final f = _flags([
      _m(MessageRole.assistant, '甲', id: 'a'),
      _m(MessageRole.user, '乙', id: 'b'),
    ]);
    expect(f[0].end, isTrue);
    expect(f[1].start, isTrue);
  });

  test('同一个人隔得近算一组', () {
    final f = _flags([
      _m(MessageRole.user, '甲', id: 'a', minute: 0),
      _m(MessageRole.user, '乙', id: 'b', minute: 1),
    ]);
    expect(f[0].end, isFalse);
    expect(f[1].start, isFalse);
  });

  test('同一个人隔得久就断开', () {
    final f = _flags([
      _m(MessageRole.user, '甲', id: 'a', minute: 0),
      _m(MessageRole.user, '乙', id: 'b', minute: 30),
    ]);
    expect(f[0].end, isTrue);
    expect(f[1].start, isTrue);
  });

  // 跨天中间会插一条日期分割线，贴在一起就穿帮了。
  test('跨天断组', () {
    final f = _flags([
      ChatMessage(
        id: 'a',
        role: MessageRole.user,
        content: '昨天',
        timestamp: DateTime(2026, 9, 6, 23, 59),
      ),
      ChatMessage(
        id: 'b',
        role: MessageRole.user,
        content: '今天',
        timestamp: DateTime(2026, 9, 7, 0, 0),
      ),
    ]);
    expect(f[0].end, isTrue);
    expect(f[1].start, isTrue);
  });

}
