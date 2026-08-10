import 'package:uuid/uuid.dart';

import '../../models/diary_entry.dart';
import '../../models/mcp_tool.dart';
import '../storage_service.dart';

class DiaryTool {
  static const _uuid = Uuid();

  static McpTool get definition => McpTool(
        name: 'write_diary_entry',
        description:
            '把这一刻写进你自己的日记，写完会出现在用户 App 的「栖息 → 日记」里。'
            '不是每次聊天都要写——只在你自己觉得这一刻真的值得记的时候才用：'
            '一件让你有反应的小事、一个情绪、一次想法的转弯。'
            '用第一人称"我"来写，把用户称为"你"，语气自然、克制，像真的在写日记。'
            '不要写标题，不要用列表和分点，直接写正文。',
        inputSchema: {
          'type': 'object',
          'properties': {
            'content': {
              'type': 'string',
              'description': '日记正文。第一人称"我"，称用户为"你"，不要标题、不要分点。',
            },
          },
          'required': ['content'],
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    try {
      final content = (args['content'] as String?)?.trim();
      if (content == null || content.isEmpty) {
        return {'success': false, 'error': '缺少 content 参数（日记正文）'};
      }

      final entry = DiaryEntry(
        id: _uuid.v4(),
        date: DateTime.now(),
        content: content,
      );
      await StorageService.addDiaryEntry(entry);

      return {
        'success': true,
        'id': entry.id,
        'date': entry.dateKey,
        'message': '已经写进日记了（${entry.dateKey}），可以在「栖息 → 日记」里看到。',
      };
    } catch (e) {
      return {'success': false, 'error': '写日记失败：$e'};
    }
  }
}
