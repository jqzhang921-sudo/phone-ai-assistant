/// 收藏的一句话是谁说的。
///
/// 「我想说」那张卡收的是它每天写的随想；聊天页收的可能是它说的，
/// 也可能是你自己说的。一隅要按作者筛选，就得记住这个。
enum MusingSource {
  /// 主页「我想说」卡片（它写的每日随想）
  musing,

  /// 聊天里它说的话
  ai,

  /// 聊天里你说的话
  user,
}

/// 这条是谁收的。和 [MusingSource]（谁**说**的）是两件正交的事：
/// 沐说的一句话，可能是你收的、它自己收的，也可能你们各自都收了。
///
/// [both] 是这个功能里唯一产生新信息的状态——它独立挑中了你也挑中的那句。
enum MusingSavedBy { user, ai, both }

class MusingEntry {
  final String id;
  final DateTime date; // 生成于哪一天
  final String content;
  final DateTime createdAt;

  /// 这句话的出处。老数据没有这个字段，一律当作 [MusingSource.musing]
  /// ——收藏功能上线时只有「我想说」一个入口。
  final MusingSource source;

  /// 从聊天里收的才有：用来点回原对话的那一条
  final String? messageId;
  final String? conversationId;

  /// 长按写的一句备注
  final String? note;

  /// 谁收的。老数据没有这个字段，一律算 [MusingSavedBy.user]——
  /// 自主收藏上线前，能收东西的只有你。
  final MusingSavedBy savedBy;

  MusingEntry({
    required this.id,
    required this.date,
    required this.content,
    DateTime? createdAt,
    this.source = MusingSource.musing,
    this.messageId,
    this.conversationId,
    this.note,
    this.savedBy = MusingSavedBy.user,
  }) : createdAt = createdAt ?? DateTime.now();

  /// 沐收的时候你已经收过了（或反过来）——升成「一起收的」
  MusingEntry get sharedWith => MusingEntry(
    id: id,
    date: date,
    content: content,
    createdAt: createdAt,
    source: source,
    messageId: messageId,
    conversationId: conversationId,
    note: note,
    savedBy: MusingSavedBy.both,
  );

  /// 能不能跳回原文
  bool get canJumpBack => conversationId != null && messageId != null;

  MusingEntry copyWith({String? note}) => MusingEntry(
    id: id,
    date: date,
    content: content,
    createdAt: createdAt,
    source: source,
    messageId: messageId,
    conversationId: conversationId,
    note: note ?? this.note,
    savedBy: savedBy,
  );

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
    'source': source.name,
    if (messageId != null) 'messageId': messageId,
    if (conversationId != null) 'conversationId': conversationId,
    if (note != null) 'note': note,
    'savedBy': savedBy.name,
  };

  factory MusingEntry.fromJson(Map<String, dynamic> json) => MusingEntry(
    id: json['id'],
    date: DateTime.parse(json['date']),
    content: json['content'],
    createdAt: DateTime.parse(json['createdAt']),
    // 老数据缺 source，落回 musing——不要在这里抛，备份文件里全是老格式
    source: MusingSource.values.firstWhere(
      (s) => s.name == json['source'],
      orElse: () => MusingSource.musing,
    ),
    messageId: json['messageId'] as String?,
    conversationId: json['conversationId'] as String?,
    note: json['note'] as String?,
    savedBy: MusingSavedBy.values.firstWhere(
      (v) => v.name == json['savedBy'],
      orElse: () => MusingSavedBy.user,
    ),
  );
}
