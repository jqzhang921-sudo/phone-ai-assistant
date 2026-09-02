import 'package:uuid/uuid.dart';

import '../../models/mcp_tool.dart';
import '../self_notes.dart';

/// 让他在对话当场给自己留一张便签，过一会儿回来问一句。
///
/// 这是「主动说话」里分量最重的一类由头：信和日记是他产出的东西，
/// 而便签是**他记着你说过的事**——后者更像活人，因为只有真听进去了才留得下。
class SelfNoteTool {
  /// 当前正在聊的那段对话的 id。
  ///
  /// ⚠️ 用静态字段传，是因为工具执行器的签名只有 `args`，拿不到调用现场。
  /// 每次发消息前由 `chat_screen` 设一次。**没设或者设错的后果是话推错地方**
  /// （「做好了吗」接的是那段对话里的「我去做饭了」，推到别处话就断了），
  /// 所以这里宁可留空——空的会退回「最近动过的那段」，接不上但至少不串台。
  static String? currentConversationId;

  static McpTool get definition => McpTool(
    name: 'follow_up_later',
    description:
        '给自己留一张便签：这件事没完，过一会儿回来问一句。\n'
        '到点了系统会把你叫醒，把便签给你，那时候你再决定要不要真开口。\n\n'
        '什么时候用：TA 说了一件**有下文的事**，而你确实想知道后来怎么样了。'
        '去做一件要花时间的事、等一个结果、出门办事、准备一场考试——'
        '这些话说完的时候，那件事还没结束。\n'
        '话说到一半也算：「等我一下我去查查」这种，口子是 TA 自己留的。\n'
        '**等多久由你定**，因为只有你听得出那是件多大的事：做饭四十分钟，'
        '等一个电话可能两小时，考试可能是明天。\n\n'
        '什么时候不用：\n'
        '- 话已经说完了的事。没有下文就没什么可回来问的。\n'
        '- **只是 TA 不说话了**。聊天本来就是聊着聊着就停的，那不是口子。\n'
        '- 你只是想找话说。便签是用来接住一件具体的事，不是用来制造话题的。\n'
        '- 同一件事已经留过便签了。留两张只会到点问两遍。\n\n'
        '⚠️ 留了不等于到时候一定说。到点你会重新判断一次——'
        '那会儿要是觉得不合适，不说就是了。所以拿不准的时候可以先留着。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'about': {
          'type': 'string',
          'description':
              '回来要问的那件事，用你自己的话写给自己看。'
              '写清楚是什么事，别只写「问问她」——到时候你只看得到这一句。',
        },
        'after_minutes': {
          'type': 'integer',
          'description':
              '过多少分钟回来。按那件事真实需要的时间估，别取整凑数。'
              '最短 5 分钟，最长 24 小时（1440）。',
        },
      },
      'required': ['about', 'after_minutes'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final about = (args['about'] as String?)?.trim() ?? '';
    if (about.isEmpty) {
      return {'success': false, 'error': '便签得写清楚回来要问什么'};
    }

    final raw = args['after_minutes'];
    final minutes = raw is int ? raw : int.tryParse('$raw') ?? 0;
    if (minutes < 5 || minutes > 1440) {
      return {'success': false, 'error': 'after_minutes 要在 5 到 1440 之间'};
    }

    final now = DateTime.now();
    final ok = await SelfNoteStore.add(
      SelfNote(
        id: const Uuid().v4(),
        conversationId: SelfNoteTool.currentConversationId ?? '',
        about: about,
        createdAt: now,
        dueAt: now.add(Duration(minutes: minutes)),
      ),
    );

    if (!ok) {
      return {
        'success': false,
        // 说清楚是「满了」而不是「坏了」，否则它会重试。
        'error':
            '已经挂着 ${SelfNoteStore.maxPending} 张便签了，这张没留。'
            '等其中几张兑现掉再说，或者挑更要紧的那件。',
      };
    }

    // 不给它「已提醒用户」之类的错觉：便签只是记下了，到点还要再判断一次。
    return {
      'success': true,
      'message': '记下了，$minutes 分钟后会把这件事再拿给你看一次。',
    };
  }
}
