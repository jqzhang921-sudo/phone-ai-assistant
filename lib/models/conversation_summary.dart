import 'chat_message.dart';
import 'conversation.dart';

/// 一场对话的**纯文本索引**：元数据 + 每条消息的正文，**不含图片**。
///
/// ## 为什么要有这个形状
///
/// 首页「最近对话」和历史搜索要的只是标题、条数、时间、每条正文。这两处原来
/// 走的是 `StorageService.listConversations()`，把每一场对话连同**全部 base64
/// 图片**一起解析进内存。真机上量过：4 场对话 2516 条消息，正文合计 953K 字符，
/// 图片 base64 合计 187,212K 字符——**图片是正文的两百倍**。
///
/// 更要命的是去处：`chat_screen` 把全量加载的结果存进 `_savedConversations`，
/// 而那个 State 活在 `home_shell` 的 IndexedStack 里，永不销毁。于是那 180 多 MB
/// 读进来一次就跟着 App 活到进程结束——这才是「用久了内存变得非常大」的那一块。
///
/// 索引把同一批对话压到只剩正文（这份数据下约 1 MB，两千五百分之一）。
/// 点进去才读原文件，走 `StorageService.loadConversation(id)`。
///
/// ## 它是缓存，不是数据
///
/// 唯一的真相是 `conversations/{id}.json`。索引丢了、坏了、版本旧了都不算错误，
/// 下次读的时候从正文重建一份就是。所以它可以随时删（移进回收站那条路上就是
/// 这么做的），写失败也可以当没发生。
class ConversationSummary {
  /// 索引的落盘格式版本。**动 [toJson] 的形状就必须改它。**
  ///
  /// 不指望「加了字段老代码也能读」——索引是纯派生数据，重建一次的代价只是
  /// 读一遍原文件。所以宁可版本不符就当读不出来，也不要拿一个字段含义已经
  /// 变了的旧索引当成对的用（那样错得无声无息）。
  static const formatVersion = 2;

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String model;
  final bool isPinned;

  /// 消息总条数，含工具消息——和 `Conversation.messages.length` 是同一个数。
  ///
  /// 单独存而不是用 `lines.length`：索引里剔掉了工具消息，两个数不一样，
  /// 而界面上写的「N 条消息」一直是总数。
  final int messageCount;

  /// 这场对话有没有自己的人格（`systemPrompt` 非空）。
  ///
  /// 只留「有没有」，不留那串字本身：全项目只有设置页要数一下有几段设了人格，
  /// 而那段提示词可能很长，收进索引等于把每份索引都撑大一遍。
  final bool hasSystemPrompt;

  /// 能搜到的那部分正文。
  final List<SummaryLine> lines;

  const ConversationSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.model,
    required this.isPinned,
    required this.messageCount,
    required this.hasSystemPrompt,
    required this.lines,
  });

  /// 从一场**完整的**对话压出索引。存盘时顺手做这件事，不用再读一遍文件。
  factory ConversationSummary.fromConversation(Conversation conv) {
    final lines = <SummaryLine>[];
    for (var i = 0; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      // 和历史搜索的口径一致：工具消息从来不参与搜索，收进来只是白占地方。
      if (m.role == MessageRole.toolCall || m.role == MessageRole.toolResult) {
        continue;
      }
      lines.add(SummaryLine(i, m.role, m.content, m.timestamp));
    }
    return ConversationSummary(
      id: conv.id,
      title: conv.title,
      createdAt: conv.createdAt,
      updatedAt: conv.updatedAt,
      model: conv.model,
      isPinned: conv.isPinned,
      messageCount: conv.messages.length,
      hasSystemPrompt: (conv.systemPrompt ?? '').isNotEmpty,
      lines: lines,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': formatVersion,
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'model': model,
    'isPinned': isPinned,
    'messageCount': messageCount,
    'hasSystemPrompt': hasSystemPrompt,
    // 每条压成 [原下标, role 名, 时间戳, 正文] 四元组。这是机器自己读的格式，
    // 键名省掉能让索引小一圈——而索引每次存盘都要重写一遍。
    'lines': [
      for (final l in lines)
        [l.index, l.role.name, l.timestamp.millisecondsSinceEpoch, l.content],
    ],
  };

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    if (json['v'] != formatVersion) {
      // 抛给调用方，它会从正文重建。见 [formatVersion]。
      throw FormatException('索引格式版本不符：${json['v']}，需要 $formatVersion');
    }
    return ConversationSummary(
      id: json['id'],
      title: json['title'] ?? '新对话',
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
      model: json['model'] ?? 'gpt-4o',
      isPinned: json['isPinned'] ?? false,
      messageCount: json['messageCount'] ?? 0,
      hasSystemPrompt: json['hasSystemPrompt'] ?? false,
      lines: [
        for (final e in (json['lines'] as List?) ?? const [])
          SummaryLine(
            (e as List)[0] as int,
            MessageRole.values.firstWhere((r) => r.name == e[1]),
            '${e[3]}',
            DateTime.fromMillisecondsSinceEpoch(e[2] as int),
          ),
      ],
    );
  }
}

/// 索引里的一条正文，配它在 `Conversation.messages` 里的**原始下标**。
///
/// 原下标必须留着：搜索命中之后要滚到那条消息（`scrollToMessageIndex`），
/// 而索引里剔掉了工具消息——按下标数一遍就会从那之后整体错位。
///
/// 时间戳也留着：栖息页、日统计、日记、收藏挑选全都要按「**每条消息自己的
/// 时间**」筛（`day_stats.dart` 原来那个 TODO 要的就是这个）。少了它，这几个
/// 调用点就只能回退到全量解析，索引也就白做了。
class SummaryLine {
  final int index;
  final MessageRole role;
  final String content;
  final DateTime timestamp;

  const SummaryLine(this.index, this.role, this.content, this.timestamp);
}
