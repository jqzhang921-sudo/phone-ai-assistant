class DiaryEntry {
  final String id;
  final DateTime date; // 这篇日记对应的日子（取当天 00:00）
  final String content;
  final DateTime createdAt;

  DiaryEntry({
    required this.id,
    required this.date,
    required this.content,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 列表页预览用的前几十字
  String get summary {
    if (content.isEmpty) return '';
    return content.length > 60 ? '${content.substring(0, 60)}...' : content;
  }

  String get dateKey {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    'content': content,
    'createdAt': createdAt.toIso8601String(),
  };

  factory DiaryEntry.fromJson(Map<String, dynamic> json) => DiaryEntry(
    id: json['id'],
    date: DateTime.parse(json['date']),
    content: json['content'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}
