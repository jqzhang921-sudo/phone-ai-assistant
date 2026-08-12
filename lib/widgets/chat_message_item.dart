import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import 'message_bubble.dart';
import 'tool_call_card.dart';

/// 一条消息该渲染成什么：气泡、工具卡片，还是什么都不画。
///
/// 三个聊天页（首页对话 / 单本书 / 多本书）原来各抄了一份一模一样的分支，
/// 空气泡这个 bug 于是同时存在于三处。统一收到这里，改一次就够。
Widget chatMessageItem(ChatMessage msg) {
  if (msg.role == MessageRole.toolCall && msg.toolCalls != null) {
    return ToolCallCard(toolCalls: msg.toolCalls!);
  }
  if (msg.role == MessageRole.toolResult) {
    return ToolResultCard(content: msg.content);
  }

  // 没有文字的 assistant 消息不要渲染气泡。
  //
  // 这条消息本身必须留在历史里（tool_calls 要原样发回服务端，缺了就 400），
  // 但界面上它只会画出一个空框子——头像、边框、时间戳，中间什么都没有。
  // 两种情况都会走到这儿：
  //   1. 模型只返工具调用、一个字都没说；
  //   2. 流式的第一个分片常常是 content:""，真正的文字还在路上。
  if (msg.role == MessageRole.assistant && msg.content.trim().isEmpty) {
    final calls = msg.toolCalls;
    if (calls != null && calls.isNotEmpty) {
      // 有调用就把工具卡片顶上来，和紧跟其后的结果卡片配成一对，
      // 展开还能看到实际传了什么参数——排查空 query 正好用得上。
      return ToolCallCard(toolCalls: calls);
    }
    return const SizedBox.shrink();
  }

  return MessageBubble(message: msg);
}
