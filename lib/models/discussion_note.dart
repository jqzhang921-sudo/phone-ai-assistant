class DiscussionNote {
  final String id;
  final String bookId;
  final String content;
  final DateTime createdAt;

  DiscussionNote({
    required this.id,
    required this.bookId,
    required this.content,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// First ~40 chars as summary for list preview
  String get summary {
    if (content.isEmpty) return '新笔记（点击展开编辑）';
    return content.length > 50 ? '${content.substring(0, 50)}...' : content;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
      };

  factory DiscussionNote.fromJson(Map<String, dynamic> json) => DiscussionNote(
        id: json['id'],
        bookId: json['bookId'],
        content: json['content'],
        createdAt: DateTime.parse(json['createdAt']),
      );
}
