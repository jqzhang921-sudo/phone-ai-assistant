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
/// [splitBubbles] 决定要不要按空行把一条消息拆成几个气泡。
///
/// 主 App 要拆：它的人设是「像发微信一样」，短句、多条、有停顿感。
///
/// **读书版不拆。** 那边的人设写的是「允许展开」「说清楚一件事比说得短重要」，
/// 回答里的空行是**段落分隔**（一段铺垫、一段追问）。拆开之后每段都成了独立
/// 发言，层层推进的感觉就没了，看着像絮叨而不是在讲道理。
///
/// 同一个函数两种行为，是因为拆气泡本来就是**人设的一部分**，不是通用排版。
List<ChatDisplayItem> groupChatItems(
  List<ChatMessage> messages, {
  List<ChatEvent> events = const [],
  bool splitBubbles = true,
}) {
  final grouped = _groupMessages(messages, splitBubbles: splitBubbles);
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

/// 把一条 assistant 消息按空行拆成几段，界面上画成几个气泡。
///
/// **只在渲染这一层拆，存的东西一个字没动。** 历史里、发回服务端的，永远是
/// 完整那一整段——按气泡拆开存的话，下一轮模型看到自己「说了三次话」，会越
/// 说越碎。人设里那条「想分几条说的时候，两条之间空一行」就是配这里用的。
///
/// 第一段**沿用原来的 id**，后面几段才加 `#1`、`#2`。这样以前收藏过、朗读过
/// 的消息，标记还认得出来——收藏和 TTS 都是按 message.id 存的，全部改 id 会
/// 让旧记录一夜之间失效。
///
/// 思考过程只挂第一段：它是整条回复的草稿，不属于某一句。
/// 整条短于这个字数就不拆，哪怕中间有空行。
///
/// 空行是它「我要分条说」的记号，但很短的两句分成两个气泡是过头了——
///
/// ```
/// 好的
///
/// 嗯
/// ```
///
/// 这拆开就是两条只有一两个字的气泡，屏幕上一串小方块，读起来比一条还累。
///
/// 15 是拍的。一开始定的 30，太狠——「今天怎么样 / 面试顺利吗」这种
/// 十几个字的一问一答是**真的两拍**，该拆。真正难看的只有「好的 / 嗯」
/// 那种一两个字的小方块。
/// 反过来「长的强制拆」没有做，那需要替它断句——空行是它的意图，
/// 长度只是我们的负担，替作者决定在哪儿喘气，断错一次就把一个完整的意思
/// 劈成了两半。
const _minLengthToSplit = 15;

List<ChatMessage> _splitIntoBubbles(ChatMessage m) {
  if (m.role != MessageRole.assistant) return [m];
  if (m.toolCalls != null && m.toolCalls!.isNotEmpty) return [m];
  if (m.content.trim().runes.length < _minLengthToSplit) return [m];

  final parts = _splitOnBlankLines(m.content);
  if (parts.length < 2) return [m];

  return [
    for (var i = 0; i < parts.length; i++)
      ChatMessage(
        id: i == 0 ? m.id : '${m.id}#$i',
        role: m.role,
        content: parts[i],
        timestamp: m.timestamp,
        metadata: m.metadata,
        // 图只跟第一段走，不然每个气泡都挂一份。
        images: i == 0 ? m.images : const [],
        thinking: i == 0 ? m.thinking : null,
      ),
  ];
}

/// 按空行切，但**代码块里的空行不算**。
///
/// 一段带空行的代码被拆成两个气泡，两半都不再是合法代码，而且第二半的 ```
/// 会把后面的正文一起吃进代码块里。
List<String> _splitOnBlankLines(String text) {
  final lines = text.split('\n');
  final parts = <String>[];
  final buf = <String>[];
  var inFence = false;

  void flush() {
    final joined = buf.join('\n').trim();
    if (joined.isNotEmpty) parts.add(joined);
    buf.clear();
  }

  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) inFence = !inFence;
    if (!inFence && line.trim().isEmpty) {
      flush();
      continue;
    }
    buf.add(line);
  }
  flush();
  return parts;
}

List<ChatDisplayItem> _groupMessages(
  List<ChatMessage> messages, {
  bool splitBubbles = true,
}) {
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
      // ⚠️ 表情消息正文就是空的（图是 metadata 里的一个 key，见 [Sticker]），
      // 所以必须在这条规则之前放行——否则它发的表情会被整条吞掉。
      //
      // 2026-09-21 Cleo：「好像它发不出来」。它确实调了 send_sticker、也确实
      // 接成了消息，是这里把它当成「还没开口的空消息」跳过了。
      if (m.role == MessageRole.assistant &&
          m.content.trim().isEmpty &&
          (m.thinking?.trim().isEmpty ?? true) &&
          m.metadata?['sticker'] == null) {
        i++;
        continue;
      }
      if (splitBubbles) {
        for (final piece in _splitIntoBubbles(m)) {
          items.add(ChatDisplayItem.message(piece));
        }
      } else {
        items.add(ChatDisplayItem.message(m));
      }
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

/// 连着多久算「一口气说的」。
///
/// 拆气泡分出来的那几段共用一个基础 id，本来就同组；这个窗口是给
/// 「他连着敲了两句」那种情况用的。
const _groupGap = Duration(minutes: 2);

/// 拆气泡给后几段加的后缀是 `#1` `#2`（见 [groupChatItems]）。
/// 去掉它才能看出两条是不是同一次回复拆出来的。
String _baseId(String id) {
  final i = id.indexOf('#');
  return i < 0 ? id : id.substring(0, i);
}

/// 这条画在谁那一边。
///
/// 它看一眼屏幕的截图挂在 user 消息上（模型才看得到图），但画在它那边——
/// 按角色分组的话，截图会和它后面那句回复断开，变成两次发言。
MessageRole _speaker(ChatMessage m) =>
    m.metadata?['glanceShot'] == true ? MessageRole.assistant : m.role;

/// 相邻两条算不算同一组。
///
/// 三个条件：**同一个人说的**、中间没夹着别的东西（工具卡、事件行会打断）、
/// 而且要么是同一条回复拆出来的、要么隔得够近。
bool _sameGroup(List<ChatDisplayItem> items, int a, int b) {
  if (a < 0 || b >= items.length) return false;
  final x = items[a].message;
  final y = items[b].message;
  if (x == null || y == null) return false;
  if (_speaker(x) != _speaker(y)) return false;
  // 跨天要断开：日期分割线会插在中间，贴在一起就穿帮了。
  if (_startsNewDay(items, b)) return false;
  if (_baseId(x.id) == _baseId(y.id)) return true;
  return y.timestamp.difference(x.timestamp).abs() <= _groupGap;
}

/// 渲染一个显示项。
Widget chatDisplayItem(
  List<ChatDisplayItem> items,
  int index, {
  String? conversationId,
  /// 她点了选项卡上的某一项。不传就是死卡片——读书版那边没有这个工具。
  void Function(ChatMessage message, String label)? onPickChoice,
}) {
  final item = items[index];
  final Widget body;
  if (item.event != null) {
    body = _EventLine(item.event!);
  } else if (item.toolRun != null) {
    body = ToolRunCard(messages: item.toolRun!);
  } else {
    // 成组：连着几条同一个人说的贴在一起，头像和尖角只出现一次。
    //
    // 这一层才看得见前后关系，单条气泡自己判断不了——和时间戳、日期分割线
    // 是同一个道理。
    body = MessageBubble(
      message: item.message!,
      showTimestamp: _shouldShowTimestamp(items, index),
      conversationId: conversationId,
      isGroupStart: !_sameGroup(items, index - 1, index),
      isGroupEnd: !_sameGroup(items, index, index + 1),
      onPickChoice: onPickChoice,
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
