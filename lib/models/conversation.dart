import 'chat_message.dart';

class Conversation {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;
  String model;
  String? systemPrompt;
  bool titleManuallySet;
  bool isPinned;

  /// 早期消息压出来的摘要。为 null 表示这段对话还没长到需要压缩。
  ///
  /// 存下来而不是每轮重算：不然每发一句话就多一次 API 调用，比省下的还贵。
  String? summary;

  /// [summary] 覆盖了 [messages] 的前多少条。这些不再逐条发给模型。
  int summarizedCount;

  Conversation({
    required this.id,
    this.title = '新对话',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    this.model = 'gpt-4o',
    this.systemPrompt,
    this.titleManuallySet = false,
    this.isPinned = false,
    this.summary,
    this.summarizedCount = 0,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       messages = messages ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
    'model': model,
    'systemPrompt': systemPrompt,
    'titleManuallySet': titleManuallySet,
    'isPinned': isPinned,
    if (summary != null) 'summary': summary,
    if (summarizedCount > 0) 'summarizedCount': summarizedCount,
  };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'],
    title: json['title'] ?? '新对话',
    createdAt: DateTime.parse(json['createdAt']),
    updatedAt: DateTime.parse(json['updatedAt']),
    messages:
        (json['messages'] as List?)
            ?.map((m) => ChatMessage.fromJson(m))
            .toList() ??
        [],
    model: json['model'] ?? 'gpt-4o',
    systemPrompt: json['systemPrompt'],
    titleManuallySet: json['titleManuallySet'] ?? false,
    isPinned: json['isPinned'] ?? false,
    summary: json['summary'] as String?,
    summarizedCount: json['summarizedCount'] as int? ?? 0,
  );
}
