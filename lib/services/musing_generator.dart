import '../models/chat_message.dart';
import '../services/ai_client.dart';
import '../services/storage_service.dart';

/// 生成一段 AI 自己的、随意的"我想说"——可以是吐槽、观察、随手一提的想法，
/// 不一定要围绕对话内容，也不强求有主题。
Future<String?> generateDailyMusing({required AiClient aiClient}) async {
  final convs = await StorageService.listConversations();
  final now = DateTime.now();

  final buf = StringBuffer();
  for (final conv in convs) {
    for (final m in conv.messages) {
      final t = m.timestamp.toLocal();
      final isToday =
          t.year == now.year && t.month == now.month && t.day == now.day;
      if (!isToday) continue;
      if (m.role != MessageRole.user && m.role != MessageRole.assistant) {
        continue;
      }
      if (m.content.trim().isEmpty) continue;
      final role = m.role == MessageRole.user ? '你' : 'AI';
      buf.writeln('$role: ${m.content}');
    }
  }
  final todayText = buf.toString();

  final contextPart =
      todayText.trim().isEmpty
          ? '今天你们还没聊过天，没有具体话题可以聊。'
          : '今天的对话记录：\n$todayText';

  final prompt =
      '写一段50~100字的"我想说"，用你自己的口吻，随便说点什么都行——'
      '可以是一句吐槽、一个突然的想法、一点小情绪，也可以跟今天聊的内容有关，'
      '也可以完全无关，只要是你自己真实想说的话。不用讨好、不用总结、不用刻意积极，'
      '像随口一说那样自然。不要写标题，不要用列表。\n\n$contextPart';

  final messages = [
    ChatMessage(id: 'musing_gen', role: MessageRole.user, content: prompt),
  ];

  String content = '';
  await for (final event in aiClient.chat(
    messages,
    systemPrompt: '你是用户的AI伙伴，此刻只是想说点自己的话，不是在完成任务。',
  )) {
    if (event.type == AiEventType.token) {
      content += event.text ?? '';
    } else if (event.type == AiEventType.done) {
      content = event.text ?? content;
    } else if (event.type == AiEventType.error) {
      throw Exception(event.error ?? '生成失败');
    }
  }

  return content.trim().isNotEmpty ? content.trim() : null;
}
