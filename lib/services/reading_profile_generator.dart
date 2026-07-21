import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';
import '../models/reading_profile.dart';
import '../services/ai_client.dart';

Future<ReadingProfile?> generateReadingProfile({
  required String bookId,
  required String bookTitle,
  required AiClient aiClient,
}) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final buf = StringBuffer();

    // 1) Discussion notes
    final prefs = await SharedPreferences.getInstance();
    final rawNotes = prefs.getString('discussions_$bookId');
    if (rawNotes != null) {
      final notes = jsonDecode(rawNotes) as List;
      if (notes.isNotEmpty) {
        buf.writeln('## 讨论笔记');
        for (final n in notes) {
          final content = n['content'] as String? ?? '';
          if (content.isNotEmpty) buf.writeln('- $content');
        }
        buf.writeln();
      }
    }

    // 2) Single-book conversation
    final singleFile =
        File('${appDir.path}/book_conversations/book_$bookId.json');
    if (await singleFile.exists()) {
      buf.writeln('## 单独讨论');
      buf.writeln(_formatConversation(singleFile));
      buf.writeln();
    }

    final material = buf.toString().trim();
    if (material.isEmpty) return null;

    // Build prompt — reading profile is different from discussion notes:
    // Discussion notes = what we talked about (事件记录)
    // Reading profile  = what I think (观点提炼)
    final prompt = '请根据以下关于《$bookTitle》的读者讨论记录，生成一份结构化的阅读档案。\n\n'
        '阅读档案是读者对这本书的综合理解，侧重观点提炼，不是讨论笔记的简单汇总。\n\n'
        '请从讨论中提取以下三个部分：\n'
        '1. 核心观点：读者对这本书的核心看法、观点和感受（列出3-5条）\n'
        '2. 未解问题：讨论中提出的尚未解答或有争议的问题（列出2-3条，如无不填）\n'
        '3. 整体印象：综合所有讨论，用一段话（100-150字）写出你对这本书的整体感觉——不要复述讨论了什么，而是表达你读完/聊完之后怎么看这本书\n\n'
        '请严格按照以下JSON格式返回，不要包含其他文字：\n'
        '{"coreOpinions": ["观点1", "观点2"], "unresolvedQuestions": ["问题1"], "discussionSummary": "整体印象"}\n\n'
        '--- 讨论记录 ---\n'
        '$material';

    final chatMessages = [
      ChatMessage(
        id: 'gen',
        role: MessageRole.user,
        content: prompt,
      )
    ];

    String content = '';
    await for (final event in aiClient.chat(
      chatMessages,
      systemPrompt: '你是一个有深度思考能力的读书伙伴。只返回JSON，不要加任何其他文字。',
    )) {
      if (event.type == AiEventType.token) {
        content += event.text ?? '';
      } else if (event.type == AiEventType.done) {
        content = event.text ?? content;
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? 'AI 调用失败');
      }
    }

    content = content.trim();

    // Try JSON parse
    try {
      // Strip markdown fences if present
      String jsonStr = content;
      if (jsonStr.startsWith('```')) {
        final start = jsonStr.indexOf('\n') + 1;
        final end = jsonStr.lastIndexOf('```');
        if (end > start) jsonStr = jsonStr.substring(start, end).trim();
        if (jsonStr.startsWith('json')) {
          jsonStr = jsonStr.substring(4).trim();
        }
      }
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      final opinions = List<String>.from(parsed['coreOpinions'] ?? []);
      final questions = List<String>.from(parsed['unresolvedQuestions'] ?? []);
      final summary = parsed['discussionSummary'] as String? ?? '';

      if (opinions.isEmpty && summary.isEmpty) return null;

      return ReadingProfile(
        bookId: bookId,
        coreOpinions: opinions,
        unresolvedQuestions: questions,
        discussionSummary: summary,
      );
    } catch (_) {
      // JSON parse failed — use raw text as summary
      if (content.isEmpty) return null;
      return ReadingProfile(
        bookId: bookId,
        coreOpinions: [],
        unresolvedQuestions: [],
        discussionSummary: content,
      );
    }
  } catch (_) {
    return null;
  }
}

String _formatConversation(File file) {
  try {
    final data = jsonDecode(file.readAsStringSync());
    final messages = data['messages'] as List? ?? [];
    if (messages.isEmpty) return '';
    final b = StringBuffer();
    for (final m in messages) {
      final role = m['role'] == 'user' ? '读者' : 'AI';
      final text = m['content'] as String? ?? '';
      if (text.isNotEmpty) b.writeln('$role: $text');
    }
    return b.toString();
  } catch (_) {
    return '';
  }
}
