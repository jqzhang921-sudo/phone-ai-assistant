import 'dart:convert';

import '../models/chat_message.dart';

/// 有调用、没结果的工具，补一条占位结果。
///
/// ## 为什么需要这个
///
/// 2026-09-16 Cleo 让它「看一眼屏幕」，卡片一直转圈：`Glance at screen、
/// find_tools · 2x · running`，展开看 `find_tools` 停在 `waiting...`，
/// 而那一轮早就结束了。
///
/// 真正断掉那一轮的是另一个 bug（思考模型要求回传 `reasoning_content`，见
/// [ReasoningComplaint]）。但断掉之后**卡片永远转圈**是这里的事：界面判断
/// 「还在跑」的唯一依据就是「这个调用有没有结果」（`ToolEntry.pending`），
/// 而 `AiClient._repairToolMessages` 只修发出去的报文、不回写存下来的对话。
///
/// 所以补在存储这一侧。卡片会显示 failed——那是实话，这个工具确实没跑完——
/// 而不是骗人地一直转。
///
/// ## ⚠️ 不能只按 tool_call_id 配对
///
/// 第一版就是只按 id 配的，结果 Cleo 那张卡照样转。原因是**空 id 是真实存在的**：
/// 流式累积时先建 `ToolCallInfo(id: '', ...)` 占位（见 `AiClient` 里那段），
/// 只有分片带了 `id` 才填上——有的中转站只在第一个分片给 id，第二个工具就一直是空的。
/// 按 id 配对时这种调用被整条跳过，于是永远补不上。
///
/// 现在两种一起算：有 id 的按 id 认，认不出的**按位置数**——一条 assistant
/// 消息带 N 个调用，紧跟其后的结果有几条就认领几个，不够的才是缺的。
bool hasOrphanToolCalls(List<ChatMessage> messages) {
  for (var i = 0; i < messages.length; i++) {
    if (_missingAfter(messages, i).isNotEmpty) return true;
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
  final out = <ChatMessage>[];

  for (var i = 0; i < messages.length; i++) {
    out.add(messages[i]);
    final missing = _missingAfter(messages, i);
    if (missing.isEmpty) continue;

    // 紧跟其后的那串结果先照抄，占位补在它们后面。
    var j = i + 1;
    while (j < messages.length && messages[j].role == MessageRole.toolResult) {
      out.add(messages[j]);
      j++;
    }
    for (final tc in missing) {
      out.add(
        ChatMessage(
          id: newId(),
          role: MessageRole.toolResult,
          // id 是空的就照样留空：界面那边有一条兜底规则，配不上 id 的结果会
          // 挂到最近一个还没结果的调用上（见 `toolRunEntries`）。
          toolCallId: tc.id,
          content: jsonEncode({'success': false, 'error': orphanError}),
        ),
      );
    }
    i = j - 1;
  }
  return out;
}

/// 占位结果里那句话。她展开卡片会看到，所以说人话。
const orphanError = '这一轮没跑完（App 被系统冻结、或者请求出错断在半路），这个工具没有结果。';

/// 第 [i] 条消息要是带工具调用，哪几个调用没拿到结果。
///
/// 返回的是**靠后的那几个**：结果是按顺序回来的，断在半路时缺的总是后面那些。
List<ToolCallInfo> _missingAfter(List<ChatMessage> messages, int i) {
  final calls = messages[i].toolCalls;
  if (calls == null || calls.isEmpty) return const [];

  // ⚠️ 往后扫**整段历史**，不是只看紧邻的那几条：模型可能在两次工具调用之间
  // 说句话，结果就被别的消息隔开了。只看紧邻的话，真结果会被当成没有，
  // 于是凭空多出一条失败。同样的坑 `AiClient._repairToolMessages` 踩过一次。
  final answeredIds = <String>{
    for (final m in messages)
      if (m.role == MessageRole.toolResult && (m.toolCallId ?? '').isNotEmpty)
        m.toolCallId!,
  };

  // 紧跟其后的那串结果：认不出 id 的调用只能靠它们按位置认领。
  final followingIds = <String>[];
  for (var j = i + 1; j < messages.length; j++) {
    if (messages[j].role != MessageRole.toolResult) break;
    followingIds.add(messages[j].toolCallId ?? '');
  }

  final pending = <ToolCallInfo>[];
  var claimedById = 0;
  for (final c in calls) {
    if (c.id.isNotEmpty && answeredIds.contains(c.id)) {
      if (followingIds.contains(c.id)) claimedById++;
      continue;
    }
    pending.add(c);
  }
  // 剩下的结果（没被 id 认走的那些）按位置认领
  final loose = followingIds.length - claimedById;
  final missing = pending.length - loose;
  if (missing <= 0) return const [];
  return pending.sublist(pending.length - missing);
}
