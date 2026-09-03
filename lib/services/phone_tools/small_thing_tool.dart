import 'package:uuid/uuid.dart';

import '../../models/mcp_tool.dart';
import '../small_things.dart';

/// 替她把一件要做的小事贴到板上。
///
/// ⚠️ 和 `follow_up_later` 一字之差就会用混，所以两边的描述都写了同一句对照：
/// **便签是它要回来问的事，小事是她要去做的事。**
class SmallThingTool {
  static McpTool get definition => McpTool(
    name: 'add_small_thing',
    description:
        '把 TA 要做的一件小事贴到栖息页那块板上。\n'
        'TA 随口一说就记下了，不用切界面。\n\n'
        '什么时候用：TA 提到一件**自己要做、但现在没做**的事——交个费、'
        '拿个快递、买点什么、某天要办的事。\n\n'
        '⚠️ 别和 follow_up_later 用混：**那个是你要回来问的事，这个是 TA 要去做'
        '的事。**「我去做饭了」→ follow_up_later（你想知道后来怎么样）；'
        '「周五得交房租」→ 这个（她要做的事，你替她记着）。\n\n'
        '不确定的时候别记。板子是 TA 的，凭空多出来一条她没打算记的东西，'
        '比漏记一条更烦人。\n'
        '记完说一句就行，不用复述内容——TA 自己知道刚说了什么。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description':
              '这件事本身，用 TA 的说法写，短。贴在板上给 TA 看的，'
              '不是给你自己看的备忘。',
        },
        'due': {
          'type': 'string',
          'description':
              '可选。什么时候之前要做，写成 YYYY-MM-DD。'
              'TA 没说时间就别填——替她安排一个日期是多事。',
        },
      },
      'required': ['text'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final text = (args['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) {
      return {'success': false, 'error': '得写清楚是什么事'};
    }

    DateTime? due;
    final rawDue = (args['due'] as String?)?.trim();
    if (rawDue != null && rawDue.isNotEmpty) {
      due = DateTime.tryParse(rawDue);
      if (due == null) {
        return {'success': false, 'error': 'due 要写成 YYYY-MM-DD'};
      }
    }

    await SmallThingStore.add(
      SmallThing(
        id: const Uuid().v4(),
        text: text,
        createdAt: DateTime.now(),
        dueAt: due,
        author: SmallThingAuthor.ai,
      ),
    );

    return {
      'success': true,
      'message': '贴上去了：$text${due == null ? '' : '（$rawDue 之前）'}',
    };
  }
}
