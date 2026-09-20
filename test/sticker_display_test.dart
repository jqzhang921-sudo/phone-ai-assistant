import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/widgets/chat_message_item.dart';

ChatMessage _sticker(String key) => ChatMessage(
  id: 's_$key',
  role: MessageRole.assistant,
  content: '',
  metadata: {'sticker': key},
);

ChatMessage _text(MessageRole role, String s) =>
    ChatMessage(id: 'm_$s', role: role, content: s);

List<ChatMessage> _shown(List<ChatMessage> messages) => [
  for (final it in groupChatItems(messages, splitBubbles: false))
    if (it.message != null) it.message!,
];

/// 它发的表情消息**正文是空的**——图是 metadata 里的一个 key（见 [Sticker]）。
/// 而显示列表原本有一条规则：空正文、没思考的 assistant 消息一律跳过
/// （那是给流式第一片 `content:""` 用的）。两者一撞，表情就被整条吞掉。
///
/// 2026-09-21 Cleo：「好像它发不出来」。它确实调了 send_sticker、也确实接成了
/// 消息，是界面这一层把它丢了。
void main() {
  test('表情消息要画出来，哪怕正文是空的', () {
    final msgs = _shown([_text(MessageRole.user, '睡了那张'), _sticker('sleep')]);
    expect(msgs.length, 2);
    expect(msgs.last.metadata?['sticker'], 'sleep');
  });

  test('真正的空消息照旧跳过——流式第一片是 content:""', () {
    final msgs = _shown([
      _text(MessageRole.user, '在吗'),
      ChatMessage(id: 'empty', role: MessageRole.assistant, content: ''),
    ]);
    expect(msgs.length, 1);
  });

  test('她自己发的表情也要画——正文是给模型看的那句隐藏文字', () {
    final msgs = _shown([
      ChatMessage(
        id: 'u1',
        role: MessageRole.user,
        content: '[表情：睡了]',
        metadata: {'sticker': 'sleep'},
      ),
    ]);
    expect(msgs.length, 1);
    expect(msgs.single.metadata?['sticker'], 'sleep');
  });
}
