import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/widgets/chat_message_item.dart';

ChatMessage _ai(String content, {String id = 'm1', String? thinking}) =>
    ChatMessage(
      id: id,
      role: MessageRole.assistant,
      content: content,
      timestamp: DateTime(2026, 9, 4, 21, 0),
      thinking: thinking,
    );

List<ChatMessage> _bubbles(ChatMessage m) =>
    groupChatItems([m]).map((i) => i.message!).toList();

void main() {
  test('没有空行就还是一个气泡，id 原样不动', () {
    final out = _bubbles(_ai('就一句话'));
    expect(out.length, 1);
    expect(out.single.id, 'm1');
  });

  test('空行拆成多个气泡', () {
    final out = _bubbles(_ai('第一句\n\n第二句\n\n第三句'));
    expect(out.map((m) => m.content).toList(), ['第一句', '第二句', '第三句']);
  });

  test('连着几个空行只算一次分隔，不产生空气泡', () {
    final out = _bubbles(_ai('上面\n\n\n\n下面'));
    expect(out.map((m) => m.content).toList(), ['上面', '下面']);
  });

  test('单条消息内部的换行不拆', () {
    final out = _bubbles(_ai('第一行\n第二行'));
    expect(out.length, 1);
    expect(out.single.content, '第一行\n第二行');
  });

  // 拆错的话两半都不再是合法代码，而且后半段的 ``` 会把下文一起吃进代码块。
  test('代码块里的空行不算分隔', () {
    final out = _bubbles(
      _ai('看这段：\n\n```dart\nvoid a() {}\n\nvoid b() {}\n```\n\n就这样'),
    );
    expect(out.length, 3);
    expect(out[1].content, contains('void a()'));
    expect(out[1].content, contains('void b()'));
  });

  // 收藏和 TTS 都按 message.id 存，第一段换了 id 就等于把旧记录作废。
  test('第一段沿用原 id，后面才加后缀', () {
    final out = _bubbles(_ai('甲\n\n乙\n\n丙', id: 'abc'));
    expect(out.map((m) => m.id).toList(), ['abc', 'abc#1', 'abc#2']);
  });

  test('思考只挂在第一个气泡上', () {
    final out = _bubbles(_ai('甲\n\n乙', thinking: '想了想'));
    expect(out[0].thinking, '想了想');
    expect(out[1].thinking, isNull);
  });

  test('用户的消息不拆', () {
    final m = ChatMessage(
      id: 'u1',
      role: MessageRole.user,
      content: '我说\n\n两段',
      timestamp: DateTime(2026, 9, 4),
    );
    expect(_bubbles(m).length, 1);
  });

  // 带 tool_calls 的那条要原样发回服务端，拆开会让调用和正文对不上。
  test('带工具调用的消息不拆', () {
    final m = ChatMessage(
      id: 't1',
      role: MessageRole.assistant,
      content: '先查一下\n\n稍等',
      timestamp: DateTime(2026, 9, 4),
      toolCalls: [ToolCallInfo(id: 'c1', name: 'search', arguments: {})],
    );
    expect(_bubbles(m).length, 1);
  });
}
