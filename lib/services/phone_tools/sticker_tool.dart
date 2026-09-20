import '../../models/mcp_tool.dart';
import '../stickers.dart';

/// 让它自己发一张 Mochi 的表情。
///
/// ## 为什么是工具，不是在正文里写标记
///
/// 和 [VoiceTool] 同一个理由：正文里塞 `[[表情:困了]]` 这种东西，解析漏一次
/// 就原样显示给她看，而且模型会在别的地方也写出来。工具调用要么调了要么没调，
/// 没有中间状态。
///
/// ## 为什么不做「自动换头像」
///
/// 2026-09-18 Cleo 看过预览之后明说不要那个。头像一直在变，是**它替她决定**
/// 界面长什么样；发表情是**它说话的一部分**，她收得到、也能不理。
/// 差别在于前者改的是她的房间，后者只是它开口的方式。
class StickerTool {
  static McpTool get definition => McpTool(
    name: 'send_sticker',
    description:
        '发一张你自己的表情（你是一只黑色的德文猫 Mochi）。'
        '在她那边显示成一张贴纸，没有文字。'
        '\n\n'
        '可以单独发，也可以说完话再补一张——就像人聊天时补一个表情。'
        '\n\n'
        '有这些：\n$stickerMenu'
        '\n\n'
        '**别每句都发。** 表情之所以有意思是因为它偶尔出现；'
        '每条都带一张，就成了标点符号。'
        '\n\n'
        '**发完不要再用文字解说**——不要说「给你发了个表情」「（叹气）」'
        '「你看我这个样子」。图就在她屏幕上，她看得见。'
        '解说自己刚做了什么，比不发还生分。'
        '\n\n'
        '正经事别用：她在问具体问题、你在给步骤或结论的时候，发表情是打岔。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': '表情的名字',
          'enum': [for (final s in kStickers) s.key],
        },
      },
      'required': ['name'],
    },
    category: '表达',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final key = args['name']?.toString().trim() ?? '';
    final sticker = stickerOf(key);
    if (sticker == null) {
      // 名字写错了就把清单原样还回去，让它自己挑一个——回一句「没有这个表情」
      // 等于把路堵死，它只会改用文字描述表情，那正是这个工具要避免的东西。
      return {
        'success': false,
        'error': '没有叫「$key」的表情。可以用的是：'
            '${kStickers.map((s) => s.key).join('、')}',
      };
    }
    // 真正让它出现在对话里的是界面那一步（chat_screen 的 _appendStickerMessage），
    // 和 send_voice 同一个路子：工具只负责产出，「这条出现在对话里」是界面的事。
    return {
      'success': true,
      'sticker': sticker.key,
      'message': '发出去了（${sticker.label}）。',
    };
  }
}
