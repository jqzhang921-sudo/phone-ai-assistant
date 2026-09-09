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
    final out = _bubbles(_ai('今天怎么样\n\n早上那个面试顺利吗\n\n累不累'));
    expect(out.map((m) => m.content).toList(), [
      '今天怎么样',
      '早上那个面试顺利吗',
      '累不累',
    ]);
  });

  test('连着几个空行只算一次分隔，不产生空气泡', () {
    final out = _bubbles(_ai('上面这一句写长一点\n\n\n\n下面这一句也是'));
    expect(out.map((m) => m.content).toList(), ['上面这一句写长一点', '下面这一句也是']);
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
    final out = _bubbles(_ai('第一句话写长点\n\n第二句话也是\n\n第三句', id: 'abc'));
    expect(out.map((m) => m.id).toList(), ['abc', 'abc#1', 'abc#2']);
  });

  test('思考只挂在第一个气泡上', () {
    final out = _bubbles(_ai('第一句话写长一点\n\n第二句话也写长一点', thinking: '想了想'));
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

  // 读书版的人设写着「允许展开」，回答里的空行是段落分隔不是分条。
  // 拆开会让层层推进的引导变成絮叨。
  test('splitBubbles: false 时不拆，整段一个气泡', () {
    final out = groupChatItems([
      _ai('第一段铺垫\n\n第二段追问\n\n第三段'),
    ], splitBubbles: false).map((i) => i.message!).toList();
    expect(out.length, 1);
    expect(out.single.content, contains('第一段铺垫'));
    expect(out.single.content, contains('第三段'));
  });

  // 这条原来是 `甲\n\n乙`，加了「太短不拆」之后那个例子会被判成一条。
  // 换成够长的，测的还是同一件事：默认拆。
  test('默认还是拆的，主 App 不受影响', () {
    expect(_bubbles(_ai('${'甲' * 20}\n\n${'乙' * 20}')).length, 2);
  });

  _tooShortToSplit();
}

/// 「太短就别拆」——2026-09-09 加的。
///
/// 空行是它「我要分条说」的记号，但两句加起来不到三十个字还拆成两个气泡，
/// 屏幕上就是一串小方块，比一整条还难读。
void _tooShortToSplit() {
  group('太短就不拆', () {
    test('「好的 / 嗯」这种不拆', () {
      final out = _bubbles(_ai('好的\n\n嗯'));
      expect(out.length, 1);
    });

    test('刚好到线的就拆', () {
      // 合计 16 字，刚过 15
      final out = _bubbles(_ai('${'一' * 8}\n\n${'二' * 8}'));
      expect(out.length, 2);
    });

    test('差一点点不拆', () {
      // 合计 12 字，不到 15
      final out = _bubbles(_ai('${'一' * 6}\n\n${'二' * 6}'));
      expect(out.length, 1);
    });

    // 长度算的是整条，不是单段——不然「很长一段 + 一个字」会因为
    // 那个字太短而整条不拆。
    test('按整条算长度，不是按最短那段', () {
      final out = _bubbles(_ai('${'一' * 30}\n\n好'));
      expect(out.length, 2);
    });
  });
}
