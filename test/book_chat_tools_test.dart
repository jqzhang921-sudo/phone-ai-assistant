import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/mcp_tool.dart';
import 'package:phone_ai_assistant/services/book_chat_streaming.dart';
import 'package:phone_ai_assistant/services/mcp_server.dart';

McpTool _tool(String name) => McpTool(
  name: name,
  description: '',
  inputSchema: const {'type': 'object'},
  category: 'x',
);

/// 书聊交给模型的工具只能是白名单里的。
///
/// 2026-09-14 发现：书聊原来把 McpServer 里全部二十几个内置工具都交给了模型，
/// 读书版装在别人手机上，模型却能拍照、定位、读剪贴板、写日记。
/// 另外 send_voice 在书聊里调了会扣钱，但界面既不画语音气泡也不画工具卡，
/// 等于悄悄吞掉。
void main() {
  test('全部内置工具过一遍白名单，只剩 web_search', () {
    final all = McpServer().registeredTools.map((r) => r.tool);
    final picked = bookChatTools(all).map((t) => t.name).toList();
    expect(picked, ['web_search']);
  });

  // 这几个是这次要挡住的具体东西，逐个点名，免得哪天有人往白名单里顺手加回去。
  test('有副作用或者涉及隐私的都不在里面', () {
    for (final n in [
      'send_voice',
      'take_photo',
      'get_location',
      'read_clipboard',
      'write_diary_entry',
      'set_alarm',
      'add_calendar_event',
      'search_news',
    ]) {
      expect(bookChatToolNames.contains(n), isFalse, reason: '$n 不该出现在书聊');
    }
  });

  // 外接 MCP（比如地图）走同一道筛子，不因为来源不同就放行。
  test('外接 MCP 的工具不在白名单里也不给', () {
    final picked = bookChatTools([
      _tool('map_search_places'),
      _tool('web_search'),
    ]);
    expect(picked.map((t) => t.name), ['web_search']);
  });

  test('一个都没有时返回空，不抛', () {
    expect(bookChatTools(const []), isEmpty);
  });
}
