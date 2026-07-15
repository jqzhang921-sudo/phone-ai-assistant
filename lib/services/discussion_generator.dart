import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../services/ai_client.dart';

Future<String?> generateDiscussionForBook({
  required String bookId,
  required String bookTitle,
  required AiClient aiClient,
}) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final file = File('${appDir.path}/book_conversations/book_$bookId.json');
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString());
    final messages = data['messages'] as List? ?? [];
    if (messages.isEmpty) return null;

    final buf = StringBuffer();
    for (final m in messages) {
      final role = m['role'] == 'user' ? '读者' : 'AI';
      final content = m['content'] as String? ?? '';
      if (content.isNotEmpty) {
        buf.writeln('$role: $content');
      }
    }
    final conversationText = buf.toString();

    final prompt =
        '请根据以下关于《$bookTitle》的读者与AI对话记录，生成一段300字左右的Discussion笔记，'
        '总结讨论的主要内容、观点碰撞、以及读者对这本书的感受和思考。'
        '用流畅自然的段落文字来写，不要用列表和分点，像一段读后感讨论笔记。\n\n'
        '对话记录：\n$conversationText';

    final chatMessages = [
      ChatMessage(
        id: 'gen',
        role: MessageRole.user,
        content: prompt,
      )
    ];

    String content = '';
    await for (final event
        in aiClient.chat(chatMessages, systemPrompt: '你是一个有深度思考能力的读书伙伴。')) {
      if (event.type == AiEventType.token) {
        content += event.text ?? '';
      } else if (event.type == AiEventType.done) {
        content = event.text ?? content;
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? '');
      }
    }

    return content.trim().isNotEmpty ? content.trim() : null;
  } catch (_) {
    return null;
  }
}
