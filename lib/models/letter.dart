enum LetterAuthor {
  ai,
  user;

  static LetterAuthor fromString(String s) => LetterAuthor.values.firstWhere(
    (e) => e.name == s,
    orElse: () => LetterAuthor.ai,
  );
}

/// 一封信。AI 写的和用户写的共用这个模型，靠 [author] 区分。
///
/// 刻意不设标题——日记和「我想说」都没有，信也不该有。日期和落款由界面渲染，
/// 不让模型写：模型不知道今天几号，让它写日期基本一定会写错。
class Letter {
  final String id;
  final LetterAuthor author;
  final String content;
  final DateTime createdAt;

  /// 回的是哪一封。null = 主动写的，不是回信。整条往来靠这个串起来，
  /// 不额外存 thread id。
  final String? replyToId;

  /// 只对 AI 写的信有意义——自己写的信不存在「未读」。
  final bool read;

  Letter({
    required this.id,
    required this.author,
    required this.content,
    DateTime? createdAt,
    this.replyToId,
    this.read = false,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isFromAi => author == LetterAuthor.ai;

  /// 按天分桶的键，与 DiaryEntry.dateKey 同契约（零填充 `YYYY-MM-DD`）。
  /// 信没有单独的 date 字段，用落笔的那一刻。
  String get dateKey {
    return '${createdAt.year.toString().padLeft(4, '0')}-'
        '${createdAt.month.toString().padLeft(2, '0')}-'
        '${createdAt.day.toString().padLeft(2, '0')}';
  }

  /// 列表页预览用
  String get summary {
    final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 50 ? '${oneLine.substring(0, 50)}…' : oneLine;
  }

  Letter copyWith({bool? read}) => Letter(
    id: id,
    author: author,
    content: content,
    createdAt: createdAt,
    replyToId: replyToId,
    read: read ?? this.read,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'author': author.name,
    'content': content,
    'createdAt': createdAt.toIso8601String(),
    if (replyToId != null) 'replyToId': replyToId,
    'read': read,
  };

  factory Letter.fromJson(Map<String, dynamic> json) => Letter(
    id: json['id'],
    author: LetterAuthor.fromString(json['author'] ?? ''),
    content: json['content'] ?? '',
    createdAt: DateTime.parse(json['createdAt']),
    replyToId: json['replyToId'] as String?,
    read: json['read'] as bool? ?? false,
  );
}
