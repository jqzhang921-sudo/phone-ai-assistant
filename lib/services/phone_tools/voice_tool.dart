import '../../models/mcp_tool.dart';
import '../voice_message.dart';

/// 让它自己决定「这句我用说的」。
///
/// ## 为什么是工具，不是在回复里加标记
///
/// 试过在正文里塞标记（比如 `[[语音]]`）的路子——那种东西一旦解析漏了就会
/// 原样显示在气泡里，用户看到一串方括号。而且模型会不小心在别处也写出来。
///
/// 工具调用是**结构化**的：它要么调了要么没调，没有中间状态。
///
/// ## 合成失败不是灾难
///
/// 没配 key、没网、额度用完——都返回 `success: false`。模型收到之后照常用
/// 文字说那句话就行。**「语音发不出去」不该变成「这句话没说出口」。**
class VoiceTool {
  static McpTool get definition => McpTool(
    name: 'send_voice',
    description:
        '用语音说一句话，而不是打字。'
        '**这条消息在用户那边只会显示成一个语音条，看不到文字**——'
        '他要长按才能转文字。所以只在「语气比字面更重要」的时候用：'
        '安慰、道歉、深夜的一句话、想让他听见你怎么说的时候。'
        '\n\n'
        '别用它讲事实、列步骤、给链接或代码——那些东西听不清也记不住，'
        '用文字发。'
        '\n\n'
        '一次说一件事，两三句以内。语音越长，听的人越累，'
        '而且合成是要花钱的。'
        '\n\n'
        '发不出去（没配语音、没网）会返回 success: false，'
        '那就照常用文字把这句说了，别提「我本来想发语音」。'
        '\n\n'
        '**发成功之后就结束了，不要再用文字说一遍，也不要说「发过去了」'
        '「你点开听」「你听见我怎么说了吧」**——语音条就在他屏幕上，'
        '他看得见。解说自己刚做了什么，比不发还生分。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': '要说的话。口语，别带 markdown、括号动作、表情符号。',
          'minLength': 1,
        },
      },
      'required': ['text'],
    },
    category: '表达',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final text = (args['text']?.toString() ?? '').trim();
    if (text.isEmpty) {
      return {'success': false, 'error': 'text 不能为空'};
    }
    // 太长的直接挡住：一条两分钟的语音没人听得完，钱还照花。
    if (text.runes.length > 220) {
      return {
        'success': false,
        'error': '这段太长了（${text.runes.length} 字），语音一次说两三句就好。'
            '拆短一点再发，或者直接用文字。',
      };
    }
    try {
      final v = await VoiceMessageService.synthesize(text);
      return {
        'success': true,
        'seconds': v.seconds,
        // 界面靠这两个字段把语音消息接出来（见 chat_screen 的工具轮次）
        'voice': v.toJson(),
        'text': text,
      };
    } catch (e) {
      return {'success': false, 'error': '$e'};
    }
  }
}
