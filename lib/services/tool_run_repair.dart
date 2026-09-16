import 'dart:convert';

import '../models/chat_message.dart';

/// 有调用、没结果的工具，补一条占位结果。
///
/// ## 为什么需要这个
///
/// 2026-09-16 Cleo 让它「看一眼屏幕」，卡片一直转圈：`Glance at screen、
/// find_tools · 2x · running`，而那一轮明明早就结束了。
///
/// 原因是两件事撞在一起：
///
/// 1. 看屏幕这条路**要求她切出 App**（全屏时要等她走开才截得到），而那正好是
///    ColorOS 冻结后台 App 的时刻（日志：`OplusHansManager ... enter SM`）。
///    这一轮被冻在半路，后面那个工具的结果没写进对话。
/// 2. 界面那张卡是按「有没有对应结果」判断的（[ToolEntry.pending]），
///    而 `AiClient._repairToolMessages` **只修发给服务端的那份报文**，
///    不回写存下来的对话。于是孤儿调用永远留着，卡片永远转圈。
///
/// 所以补在存储这一侧：一轮收尾时扫一遍，没结果的补上。卡片会显示 failed
/// ——那是实话，这个工具确实没跑完——而不是骗人地一直转。
///
/// 服务端那边的兜底照旧留着：两处防的是同一件事，但那处防的是「历史已经坏了、
/// 发出去会一直 400」，这处防的是「她看着一个永远不会停的圈」。
bool hasOrphanToolCalls(List<ChatMessage> messages) {
  final answered = _answeredIds(messages);
  for (final m in messages) {
    for (final tc in m.toolCalls ?? const []) {
      if (tc.id.isNotEmpty && !answered.contains(tc.id)) return true;
    }
  }
  return false;
}

/// 返回补好的那份消息列表。原列表不动。
///
/// 占位结果插在**那一组已有结果的后面**：`assistant(tool_calls)` 和它的
/// tool 结果必须挨着，插错位置等于把历史弄坏成另一种样子。
List<ChatMessage> repairOrphanToolCalls(
  List<ChatMessage> messages, {
  required String Function() newId,
}) {
  final answered = _answeredIds(messages);
  final out = <ChatMessage>[];

  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    out.add(m);
    final calls = m.toolCalls;
    if (calls == null || calls.isEmpty) continue;

    // 紧跟其后的那串结果先照抄。
    var j = i + 1;
    while (j < messages.length && messages[j].role == MessageRole.toolResult) {
      out.add(messages[j]);
      j++;
    }
    for (final tc in calls) {
      if (tc.id.isEmpty || answered.contains(tc.id)) continue;
      out.add(
        ChatMessage(
          id: newId(),
          role: MessageRole.toolResult,
          content: jsonEncode({
            'success': false,
            'error': orphanError,
          }),
          toolCallId: tc.id,
        ),
      );
    }
    i = j - 1;
  }
  return out;
}

/// 占位结果里那句话。她展开卡片会看到，所以说人话。
const orphanError = '这一轮没跑完（App 被系统冻结或退出了），这个工具没有结果。';

/// ⚠️ 往后扫**整段历史**，不是只看紧邻的那几条。
///
/// 模型可能在两次工具调用之间说句话，结果就被别的消息隔开了；
/// 只看紧邻的话，真结果会被当成没有，于是补一条占位，界面上凭空多一条失败。
/// 同样的坑 `AiClient._repairToolMessages` 踩过一次，注释在那边。
Set<String> _answeredIds(List<ChatMessage> messages) => {
  for (final m in messages)
    if (m.role == MessageRole.toolResult && m.toolCallId != null)
      m.toolCallId!,
};
