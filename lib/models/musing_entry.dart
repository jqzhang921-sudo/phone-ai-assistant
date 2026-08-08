class MusingEntry {
  final String id;
  final DateTime date; // 生成于哪一天
  final String content;
  final DateTime createdAt;

  MusingEntry({
    required this.id,
    required this.date,
    required this.content,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

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

  factory MusingEntry.fromJson(Map<String, dynamic> json) => MusingEntry(
    id: json['id'],
    date: DateTime.parse(json['date']),
    content: json['content'],
    createdAt: DateTime.parse(json['createdAt']),
  );
}
