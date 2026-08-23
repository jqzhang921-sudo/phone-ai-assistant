enum MessageRole { user, assistant, system, toolCall, toolResult }

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final List<ToolCallInfo>? toolCalls;
  final String? toolCallId;
  final Map<String, dynamic>? metadata;
  /// 用户消息带的图，base64。**一条消息可以有多张。**
  ///
  /// 原来是单个 `imageData`——不是刻意设计成一张，是当时选图就直接发了，
  /// 根本没有「攒几张再发」这个环节，一张就够用。等到能先选后发，
  /// 单张这个形状立刻就不够了。
  ///
  /// 空列表而不是 null：调用方不用到处判空，`isEmpty` 一个说法走到底。
  final List<String> images;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.toolCalls,
    this.toolCallId,
    this.metadata,
    List<String>? images,
  }) : images = List.unmodifiable(images ?? const []),
       timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
    'toolCalls': toolCalls?.map((t) => t.toJson()).toList(),
    'toolCallId': toolCallId,
    if (images.isNotEmpty) 'images': images,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    role: MessageRole.values.firstWhere((r) => r.name == json['role']),
    content: json['content'],
    timestamp: DateTime.parse(json['timestamp']),
    toolCalls:
        (json['toolCalls'] as List?)
            ?.map((t) => ToolCallInfo.fromJson(t))
            .toList(),
    toolCallId: json['toolCallId'],
    // 兼容单图老数据：以前存的是 imageData（单个字符串）。
    // 聊天记录是用户最不能丢的东西，读不出来就等于把历史里的图弄没了。
    images:
        (json['images'] as List?)?.map((e) => '$e').toList() ??
        [if (json['imageData'] != null) json['imageData'] as String],
  );

  ChatMessage copyWith({
    String? content,
    List<ToolCallInfo>? toolCalls,
    List<String>? images,
  }) => ChatMessage(
    id: id,
    role: role,
    content: content ?? this.content,
    timestamp: timestamp,
    toolCalls: toolCalls ?? this.toolCalls,
    toolCallId: toolCallId,
    metadata: metadata,
    images: images ?? this.images,
  );
}

class ToolCallInfo {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;
  final String? result;

  ToolCallInfo({
    required this.id,
    required this.name,
    required this.arguments,
    this.result,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    'result': result,
  };

  factory ToolCallInfo.fromJson(Map<String, dynamic> json) => ToolCallInfo(
    id: json['id'],
    name: json['name'],
    arguments: Map<String, dynamic>.from(json['arguments']),
    result: json['result'],
  );
}
