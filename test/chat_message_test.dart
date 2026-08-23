import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';

void main() {
  test('老的单图消息（imageData）读得出来，不能把历史里的图弄没', () {
    final msg = ChatMessage.fromJson({
      'id': 'm1',
      'role': 'user',
      'content': '看看这个',
      'timestamp': '2026-08-22T10:00:00.000',
      // 旧格式：单个字符串
      'imageData': 'AAAA',
    });

    expect(msg.images, ['AAAA']);
    // 再写回去时用新字段，老字段不再产出
    expect(msg.toJson()['images'], ['AAAA']);
    expect(msg.toJson().containsKey('imageData'), isFalse);
  });

  test('新的多图消息按顺序读写', () {
    final msg = ChatMessage.fromJson({
      'id': 'm2',
      'role': 'user',
      'content': '三张',
      'timestamp': '2026-08-22T10:00:00.000',
      'images': ['A', 'B', 'C'],
    });

    // 顺序有意义：模型看到的先后就是用户选的先后
    expect(msg.images, ['A', 'B', 'C']);
    expect(ChatMessage.fromJson(msg.toJson()).images, ['A', 'B', 'C']);
  });

  test('没有图的消息拿到空列表，不是 null', () {
    final msg = ChatMessage.fromJson({
      'id': 'm3',
      'role': 'assistant',
      'content': '嗯',
      'timestamp': '2026-08-22T10:00:00.000',
    });

    expect(msg.images, isEmpty);
    // 空列表不该写进 JSON，白占地方
    expect(msg.toJson().containsKey('images'), isFalse);
  });

  test('images 不可变——拿到手就别想改', () {
    final msg = ChatMessage(
      id: 'm4',
      role: MessageRole.user,
      content: 'x',
      images: ['A'],
    );
    expect(() => msg.images.add('B'), throwsUnsupportedError);
  });
}
