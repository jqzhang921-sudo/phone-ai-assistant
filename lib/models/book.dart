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

  /// 在 App 里被标记成「已读」的时刻。写信时靠它筛出「这段时间读完的书」。
  ///
  /// 老数据和从微信读书导入时就已经是「已读」的书都是 null——那些不算
  /// 「刚读完」，不该被当成新素材。只有在 App 内发生的状态变化才记。
  DateTime? finishedAt;

  Book({
    required this.id,
    required this.title,
    this.author,
    this.coverPath,
    this.status = ReadingStatus.wantToRead,
    DateTime? createdAt,
    this.wereadBookId,
    this.finishedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 改状态请走这里，别直接赋值 [status]——finishedAt 要跟着一起维护。
  void changeStatus(ReadingStatus next) {
    if (next == status) return;
    status = next;
    finishedAt = next == ReadingStatus.done ? DateTime.now() : null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'coverPath': coverPath,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        if (wereadBookId != null) 'wereadBookId': wereadBookId,
        if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'],
        title: json['title'],
        author: json['author'] as String?,
        coverPath: json['coverPath'] as String?,
        status: ReadingStatus.fromString(json['status'] ?? ''),
        createdAt: DateTime.parse(json['createdAt']),
        wereadBookId: json['wereadBookId'] as String?,
        finishedAt:
            json['finishedAt'] == null
                ? null
                : DateTime.tryParse(json['finishedAt']),
      );
}
