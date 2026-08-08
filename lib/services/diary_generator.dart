import '../models/chat_message.dart';
import '../services/ai_client.dart';
import '../services/storage_service.dart';

/// 读取当天全部对话（跨所有会话），生成一段日记体短文。
/// 返回 null 表示今天没有任何对话内容可写。
Future<String?> generateTodayDiary({required AiClient aiClient}) async {
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
  final favoritedMusings = await StorageService.listFavoritedMusingsForToday();

  if (todayText.trim().isEmpty && favoritedMusings.isEmpty) return null;

  final musingPart =
      favoritedMusings.isEmpty
          ? ''
          : '\n\n你今天说过的话里，有这些被用户收藏了（说明这些话对TA来说有点分量，'
              '要不要写进日记你自己判断）：\n'
              '${favoritedMusings.map((m) => '- ${m.content}').join('\n')}';

  final prompt =
      '这是你和用户今天的对话记录。请以你自己的口吻，写一篇150~250字的日记，'
      '记录今天你们之间发生的、值得记住的一两件事——可以是一句让你印象深的话，'
      '一个小情绪，一次讨论。不要逐条总结对话，只挑最值得记的部分展开写。'
      '用第一人称"我"来写，把用户称为"你"，语气自然、克制，像真的在写日记，'
      '不要用列表和分点，也不要写标题。\n\n'
      '今天的对话：\n$todayText$musingPart';

  final messages = [
    ChatMessage(id: 'diary_gen', role: MessageRole.user, content: prompt),
  ];

  String content = '';
  await for (final event in aiClient.chat(
    messages,
    systemPrompt: '你是用户长期陪伴的AI伙伴，正在写一篇属于你自己的日记。',
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
