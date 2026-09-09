import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/chat_message.dart';
import 'package:phone_ai_assistant/widgets/tool_call_card.dart';

/// 一次调用 + 一条结果，问界面把它算成成功还是失败。
///
/// ## 为什么值得单独测
///
/// 2026-09-08：`map_search_places · 4x · 4 failed` 一片红，展开却是
/// `"status":"0","message":"ok"` 加三组真实经纬度。判定只认自己那套工具的
/// `success` 字段，外部 MCP 的 `{content, isError}` 一律算失败。
///
/// **一个错误的红标记，让我和 Cleo 都误判了一次**——我据此说模型在编距离，
/// 其实数据是真的。所以这条规则的方向是：**看不出失败就算成功。**
bool _ok(String resultJson) {
  final entries = toolRunEntries([
    ChatMessage(
      id: 'c1',
      role: MessageRole.toolCall,
      content: '',
      timestamp: DateTime(2026, 9, 8),
      toolCalls: [ToolCallInfo(id: 't1', name: 'demo', arguments: {})],
    ),
    ChatMessage(
      id: 'r1',
      role: MessageRole.toolResult,
      content: resultJson,
      timestamp: DateTime(2026, 9, 8),
      toolCallId: 't1',
    ),
  ]);
  return entries.single.ok;
}

void main() {
  // send_voice 的结果**本身就是一条可见的语音气泡**，工具卡是重复的；
  // 更要紧的是展开之后会把 text: 原样抖出来，
  // 而「语音不显示文字」正是那个功能成立的前提。
  test('send_voice 不出现在工具卡里', () {
    final entries = toolRunEntries([
      ChatMessage(
        id: 'c1',
        role: MessageRole.toolCall,
        content: '',
        timestamp: DateTime(2026, 9, 9),
        toolCalls: [ToolCallInfo(id: 't1', name: 'send_voice', arguments: {})],
      ),
      ChatMessage(
        id: 'r1',
        role: MessageRole.toolResult,
        content: '{"success":true,"text":"听我说一句"}',
        timestamp: DateTime(2026, 9, 9),
        toolCallId: 't1',
      ),
    ]);
    expect(entries, isEmpty);
  });

  // 藏一个不能把同一批里别的工具也带跑偏
  test('同一批里别的工具照常显示', () {
    final entries = toolRunEntries([
      ChatMessage(
        id: 'c1',
        role: MessageRole.toolCall,
        content: '',
        timestamp: DateTime(2026, 9, 9),
        toolCalls: [
          ToolCallInfo(id: 't1', name: 'send_voice', arguments: {}),
          ToolCallInfo(id: 't2', name: 'web_search', arguments: {}),
        ],
      ),
      ChatMessage(
        id: 'r1',
        role: MessageRole.toolResult,
        content: '{"success":true}',
        timestamp: DateTime(2026, 9, 9),
        toolCallId: 't1',
      ),
      ChatMessage(
        id: 'r2',
        role: MessageRole.toolResult,
        content: '{"success":true,"results":[]}',
        timestamp: DateTime(2026, 9, 9),
        toolCallId: 't2',
      ),
    ]);
    expect(entries.length, 1);
    expect(entries.single.name, 'web_search');
    expect(entries.single.ok, isTrue);
  });

  group('自家工具的形状', () {
    test('success: true → 成功', () {
      expect(_ok(jsonEncode({'success': true, 'results': []})), isTrue);
    });

    test('success: false → 失败', () {
      expect(_ok(jsonEncode({'success': false, 'error': '没搜到'})), isFalse);
    });
  });

  group('外部 MCP 的形状', () {
    // 这就是 map_search_places 回来的样子：没有 success 这个键。
    test('isError: false → 成功（原来这里全被标红）', () {
      expect(
        _ok(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': '{"status":"0","message":"ok"}'},
            ],
            'isError': false,
          }),
        ),
        isTrue,
      );
    });

    test('isError: true → 失败', () {
      expect(_ok(jsonEncode({'content': [], 'isError': true})), isFalse);
    });

    test('连 isError 都没有也算成功——认不出的形状不当失败', () {
      expect(_ok(jsonEncode({'content': []})), isTrue);
    });
  });

  group('解析不出来的时候', () {
    // 老版本用 Map.toString() 存的结果，不是合法 JSON。
    test('Dart toString 的结果，看得出 success: true 就算成功', () {
      expect(_ok('{success: true, query: 余耕 金枝玉叶 小说}'), isTrue);
    });

    test('Dart toString 里写着 success: false 才算失败', () {
      expect(_ok('{success: false, error: 超时}'), isFalse);
    });

    test('裸的错误字符串算失败', () {
      expect(_ok('错误: 工具 demo 未找到'), isFalse);
    });

    test('完全看不懂的一坨，算成功', () {
      expect(_ok('随便什么东西'), isTrue);
    });
  });
}
