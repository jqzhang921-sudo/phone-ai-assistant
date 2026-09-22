import '../../models/mcp_tool.dart';

/// 给她一张选项卡：一句问题 + 两到四个选项，点一个就算答了。
///
/// 2026-09-22 Cleo：「有时候我想做什么东西，可能方式比较多的时候，你就会给我
/// 一个选项卡，Nook 里面可以做吗」。
///
/// ## 为什么工具放完就结束，不等她点
///
/// 聊天里的工具有 60 秒超时（chat_screen 的 `_toolTimeout`）。真等她点，
/// 她去倒杯水回来这一轮就已经超时报错了。所以这里和 `send_voice`、
/// `send_sticker` 走同一条路：**工具只负责产出，「这条出现在对话里」是界面的事**。
/// 她点了哪个，作为**她的下一条消息**发出去，对话自然往下走。
///
/// 好处还有一个：她可以**不理这张卡**，直接打字说别的。卡片是建议，不是拦路的弹窗。
class ChoiceTool {
  static McpTool get definition => McpTool(
    name: 'ask_choice',
    description:
        '给 TA 一张选项卡：一句问题，两到四个选项，TA 点一个就算回答了。\n\n'
        '**什么时候用**：真的有几条路、而且分别通向不同结果，'
        'TA 的偏好会改变你接下来怎么做。比如「这个功能是做成 A 还是 B」。\n\n'
        '**什么时候别用**：\n'
        '· 是非题——直接问就行，别为一个「要不要」画张卡。\n'
        '· **有明显更好的那条路**——那就直接建议，别用选项卡把决定推回给 TA。'
        '把一个你已经有答案的问题摆成选择题，是偷懒，不是尊重。\n'
        '· 选项超过四个——那是菜单不是提问，说明你还没想清楚该问什么。\n'
        '· 一次给好几张——一次只问一件事。\n\n'
        '每个选项写一行 note 说明代价或后果，别只写名字：'
        'TA 要能凭那一行判断，而不是凭猜。\n\n'
        '发完就停下等 TA 点，**不要再用文字把选项复述一遍**——卡片就在 TA 屏幕上。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': '一句话问题。短，别带铺垫。',
          'minLength': 1,
        },
        'options': {
          'type': 'array',
          'minItems': 2,
          'maxItems': 4,
          'description': '两到四个选项。',
          'items': {
            'type': 'object',
            'properties': {
              'label': {'type': 'string', 'description': '选项名，几个字。'},
              'note': {'type': 'string', 'description': '一行说明：这条路的代价或后果。'},
            },
            'required': ['label'],
          },
        },
      },
      'required': ['question', 'options'],
    },
    category: '表达',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final question = (args['question']?.toString() ?? '').trim();
    if (question.isEmpty) {
      return {'success': false, 'error': 'question 不能为空'};
    }
    final raw = args['options'];
    if (raw is! List || raw.length < 2) {
      return {'success': false, 'error': '至少要两个选项，不然不叫选择'};
    }
    if (raw.length > 4) {
      return {
        'success': false,
        'error': '最多四个选项。超过四个就是菜单了——先想清楚真正要问的是什么。',
      };
    }
    final options = <Map<String, String>>[];
    for (final o in raw) {
      final label = (o is Map ? o['label']?.toString() : '$o')?.trim() ?? '';
      if (label.isEmpty) {
        return {'success': false, 'error': '每个选项都要有 label'};
      }
      final note = o is Map ? (o['note']?.toString().trim() ?? '') : '';
      options.add({'label': label, if (note.isNotEmpty) 'note': note});
    }
    // 真正让它出现在对话里的是界面那一步（chat_screen 的 _appendChoiceMessage），
    // 和语音、表情同一个路子。
    return {
      'success': true,
      'question': question,
      'options': options,
      'message': '卡片发出去了，等 TA 点。别再用文字复述一遍选项。',
    };
  }
}
