enum ReadingStatus {
  wantToRead, // 想读
  reading,    // 在读
  done;       // 已读

  String get label {
    switch (this) {
      case ReadingStatus.wantToRead: return '想读';
      case ReadingStatus.reading:    return '在读';
      case ReadingStatus.done:       return '已读';
    }
  }

  ReadingStatus get next {
    switch (this) {
      case ReadingStatus.wantToRead: return ReadingStatus.reading;
      case ReadingStatus.reading:    return ReadingStatus.done;
      case ReadingStatus.done:       return ReadingStatus.wantToRead;
    }
  }

  static ReadingStatus fromString(String s) {
    return ReadingStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => ReadingStatus.wantToRead,
    );
  }
}

class Book {
  final String id;
  String title;
  String? author;
  String? coverPath;
  ReadingStatus status;
  final DateTime createdAt;
  String? wereadBookId;

  Book({
    required this.id,
    required this.title,
    this.author,
    this.coverPath,
    this.status = ReadingStatus.wantToRead,
    DateTime? createdAt,
    this.wereadBookId,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverPath': coverPath,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (wereadBookId != null) 'wereadBookId': wereadBookId,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'],
        title: json['title'],
        author: json['author'] as String?,
        coverPath: json['coverPath'] as String?,
        status: ReadingStatus.fromString(json['status'] ?? ''),
        createdAt: DateTime.parse(json['createdAt']),
        wereadBookId: json['wereadBookId'] as String?,
      );
}
