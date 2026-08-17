import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'message_bubble.dart';
import 'tool_call_card.dart';

/// 列表里实际渲染的一项：一条普通消息，或者一整段连续的工具调用。
class ChatDisplayItem {
  /// 普通消息（渲染成气泡）
  final ChatMessage? message;

  /// 一段连续的工具消息（调用 + 结果，折成一行）
  final List<ChatMessage>? toolRun;

  const ChatDisplayItem.message(ChatMessage this.message) : toolRun = null;
  const ChatDisplayItem.toolRun(List<ChatMessage> this.toolRun) : message = null;

  /// ListView 的 key 用它，避免重建时状态错位
  String get key =>
      message?.id ?? 'run_${toolRun!.first.id}_${toolRun!.length}';
}

/// 这条消息是不是「工具过程」而非「说的话」。
///
/// 三种都算：老的 toolCall 角色、工具结果、以及只发了调用一个字没说的 assistant。
/// 最后那种消息必须留在历史里（tool_calls 要原样发回服务端），但界面上它只会
/// 画出一个空框子——头像、边框、时间戳，中间什么都没有。
bool _isToolNoise(ChatMessage m) {
  if (m.role == MessageRole.toolResult) return true;
  if (m.role == MessageRole.toolCall && m.toolCalls != null) return true;
  if (m.role == MessageRole.assistant &&
      m.content.trim().isEmpty &&
      m.toolCalls != null &&
      m.toolCalls!.isNotEmpty) {
    return true;
  }
  return false;
}

/// 把消息列表折成显示项：连续的工具消息合并成一组。
///
/// 为什么要跨消息分组：模型连着调三轮工具，原来界面上就是六行「🔧 web_search /
/// ✓ 完成」交替，把真正的回复挤出屏幕。工具调用是过程信息，不该比结论还占地方。
/// 单条消息自己看不出「后面还有没有」，所以分组只能在这一层做。
List<ChatDisplayItem> groupChatItems(List<ChatMessage> messages) {
  final items = <ChatDisplayItem>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    if (!_isToolNoise(m)) {
      // 流式的第一个分片常常是 content:""，真正的文字还在路上，先什么都不画
      if (m.role == MessageRole.assistant && m.content.trim().isEmpty) {
        i++;
        continue;
      }
      items.add(ChatDisplayItem.message(m));
      i++;
      continue;
    }
    final start = i;
    while (i < messages.length && _isToolNoise(messages[i])) {
      i++;
    }
    items.add(ChatDisplayItem.toolRun(messages.sublist(start, i)));
  }
  return items;
}

/// 渲染一个显示项。
Widget chatDisplayItem(ChatDisplayItem item) {
  if (item.toolRun != null) return ToolRunCard(messages: item.toolRun!);
  return MessageBubble(message: item.message!);
}
