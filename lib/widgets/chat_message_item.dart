import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../config/app_shape.dart';
import '../services/chat_events.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'message_bubble.dart';
import 'tool_call_card.dart';

/// 列表里实际渲染的一项：一条普通消息、一整段连续的工具调用，或者一行事件。
class ChatDisplayItem {
  /// 普通消息（渲染成气泡）
  final ChatMessage? message;

  /// 一段连续的工具消息（调用 + 结果，折成一行）
  final List<ChatMessage>? toolRun;

  /// 在别处发生的事（写了信、记了日记），渲染成一行小字。
  final ChatEvent? event;

  const ChatDisplayItem.message(ChatMessage this.message)
    : toolRun = null,
      event = null;
  const ChatDisplayItem.toolRun(List<ChatMessage> this.toolRun)
    : message = null,
      event = null;
  const ChatDisplayItem.event(ChatEvent this.event)
    : message = null,
      toolRun = null;

  /// ListView 的 key 用它，避免重建时状态错位
  String get key =>
      message?.id ??
      (event != null
          ? 'ev_${event!.kind}_${event!.at.millisecondsSinceEpoch}'
          : 'run_${toolRun!.first.id}_${toolRun!.length}');
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
/// [events] 是在别处发生、要按时间插进这条时间线的事（写了信、记了日记）。
/// 按时间穿插，不改变消息本身的顺序。
List<ChatDisplayItem> groupChatItems(
  List<ChatMessage> messages, {
  List<ChatEvent> events = const [],
}) {
  final grouped = _groupMessages(messages);
  if (events.isEmpty) return grouped;

  // 事件按时间插进去。**只插到消息之间**，不在最前面堆一片——
  // 那会让人以为是新消息。
  final out = <ChatDisplayItem>[];
  var e = 0;
  for (final item in grouped) {
    final t = _itemTime(item);
    while (e < events.length && t != null && !events[e].at.isAfter(t)) {
      out.add(ChatDisplayItem.event(events[e]));
      e++;
    }
    out.add(item);
  }
  // 比最后一条消息还新的，落在末尾——「刚刚写了封信」就是这一类，
  // 而且它恰好是最该被看见的那种。
  for (; e < events.length; e++) {
    out.add(ChatDisplayItem.event(events[e]));
  }
  return out;
}

List<ChatDisplayItem> _groupMessages(List<ChatMessage> messages) {
  final items = <ChatDisplayItem>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    if (!_isToolNoise(m)) {
      // 流式的第一个分片常常是 content:""，真正的文字还在路上，先什么都不画。
      //
      // 但推理模型是**先想完再开口**的：那段时间里 content 一直是空的，只有
      // thinking 在长。这里要是照旧跳过，屏幕上就几十秒什么都没有——所以有
      // 思考就得画出来，正文晚点到没关系。
      if (m.role == MessageRole.assistant &&
          m.content.trim().isEmpty &&
          (m.thinking?.trim().isEmpty ?? true)) {
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

/// 跨过这么久才再说话，就重新报一次时间。
const _timestampGap = Duration(minutes: 5);

/// 这条要不要挂时间戳：只在整段的最后一条、或者距上一条超过 5 分钟时挂。
///
/// 原来每条气泡下面都跟一行完整的 `time: 2026-08-18 21:40:02`，
/// 一屏十几条就是十几行灰字——聊天页「显碎」主要就是它。
/// 和分组一样，单条消息自己看不出前后关系，只能在这一层判断。
bool _shouldShowTimestamp(List<ChatDisplayItem> items, int index) {
  final m = items[index].message;
  if (m == null) return false;
  if (index == items.length - 1) return true;
  for (var i = index - 1; i >= 0; i--) {
    final prev = items[i].message;
    if (prev == null) continue;
    return m.timestamp.difference(prev.timestamp).abs() >= _timestampGap;
  }
  return true; // 前面没有普通消息，这是开头第一条
}

DateTime? _itemTime(ChatDisplayItem item) =>
    item.message?.timestamp ?? item.toolRun?.first.timestamp ?? item.event?.at;

/// 这一项是不是新的一天的头一条。
bool _startsNewDay(List<ChatDisplayItem> items, int index) {
  final t = _itemTime(items[index]);
  if (t == null) return false;
  if (index == 0) return true;
  final prev = _itemTime(items[index - 1]);
  if (prev == null) return false;
  return t.year != prev.year || t.month != prev.month || t.day != prev.day;
}

/// 渲染一个显示项。
Widget chatDisplayItem(
  List<ChatDisplayItem> items,
  int index, {
  String? conversationId,
}) {
  final item = items[index];
  final Widget body;
  if (item.event != null) {
    body = _EventLine(item.event!);
  } else if (item.toolRun != null) {
    body = ToolRunCard(messages: item.toolRun!);
  } else {
    body = MessageBubble(
      message: item.message!,
      showTimestamp: _shouldShowTimestamp(items, index),
      conversationId: conversationId,
    );
  }
  if (!_startsNewDay(items, index)) return body;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [_DateDivider(_itemTime(item)!), body],
  );
}

/// 在别处发生的事，在时间线上留的一行。
///
/// 样式**故意和日期分割线一样**：居中、小、灰。它不是谁在说话，是时间线上
/// 发生过一件事——和「今天」那条胶囊是同一类东西，就该长得像。
///
/// 做成气泡是错的：那等于它开了口，可它并没有，只是做了件事。
class _EventLine extends StatelessWidget {
  final ChatEvent event;

  const _EventLine(this.event);

  IconData get _icon => switch (event.kind) {
    'letter' => PhosphorIconsRegular.envelopeSimple,
    'diary' => PhosphorIconsRegular.waves,
    _ => PhosphorIconsRegular.circle,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 2, bottom: 14),
        padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 11, color: scheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Text(
              event.text,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// 跨天时插在中间的那条小胶囊。
///
/// 每条气泡的时间戳收敛掉之后，「这是哪一天」就没地方落了——
/// 由它接住。日期归它，时刻归气泡下面那行，两边不重复。
class _DateDivider extends StatelessWidget {
  final DateTime day;

  const _DateDivider(this.day);

  String get _label {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(day.year, day.month, day.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (d.year == today.year) return '${d.month} 月 ${d.day} 日';
    return '${d.year} 年 ${d.month} 月 ${d.day} 日';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 6, bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.045),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          _label,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
