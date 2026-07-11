import '../../models/mcp_tool.dart';

class TimeTool {
  static McpTool get definition => McpTool(
        name: 'get_time',
        description: '获取手机当前的时间',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
        category: '手机工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    final now = DateTime.now();
    return {
      'success': true,
      'time': now.toIso8601String(),
      'formatted': '${now.year}年${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      'message': '当前手机时间是 ${now.year}年${now.month}月${now.day}日 ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    };
  }
}
