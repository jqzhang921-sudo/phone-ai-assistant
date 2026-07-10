enum MessageRole {
  user,
  assistant,
  system,
  toolCall,
  toolResult,
}

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final List<ToolCallInfo>? toolCalls;
  final String? toolCallId;
  final Map<String, dynamic>? metadata;
  final String? imageData; // base64 encoded image for user messages

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.toolCalls,
    this.toolCallId,
    this.metadata,
    this.imageData,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'timestamp': timestamp.toIso8601String(),
        'toolCalls': toolCalls?.map((t) => t.toJson()).toList(),
        'toolCallId': toolCallId,
        if (imageData != null) 'imageData': imageData,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'],
        role: MessageRole.values.firstWhere((r) => r.name == json['role']),
        content: json['content'],
        timestamp: DateTime.parse(json['timestamp']),
        toolCalls: (json['toolCalls'] as List?)
            ?.map((t) => ToolCallInfo.fromJson(t))
            .toList(),
        toolCallId: json['toolCallId'],
        imageData: json['imageData'] as String?,
      );

  ChatMessage copyWith(
          {String? content, List<ToolCallInfo>? toolCalls, String? imageData}) =>
      ChatMessage(
        id: id,
        role: role,
        content: content ?? this.content,
        timestamp: timestamp,
        toolCalls: toolCalls ?? this.toolCalls,
        toolCallId: toolCallId,
        metadata: metadata,
        imageData: imageData ?? this.imageData,
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
