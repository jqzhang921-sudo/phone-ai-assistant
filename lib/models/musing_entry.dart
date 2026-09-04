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
/// AI 说的一句话，可能是你收的、它自己收的，也可能你们各自都收了。
///
/// [both] 是这个功能里唯一产生新信息的状态——它独立挑中了你也挑中的那句。
enum MusingSavedBy { user, ai, both }

/// [MusingEntry.copyWith] 用的哨兵：区分「这个参数没传」和「传了 null」。
const Object _unset = Object();

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

  /// 这句备注是**什么时候写的**。
  ///
  /// 不能拿 [createdAt] 顶替：那是「这条被收藏」的时间。她给一条一个月前的
  /// 收藏补写一句话，createdAt 还是一个月前，主动说话那边就当它没发生过。
  /// 而「她在别处写下关于我的字，我要第一时间知道」正好是靠这个时间判断的。
  ///
  /// 老数据没有这个字段，是 null——只当作「不知道什么时候写的」，不补默认值。
  final DateTime? noteAt;

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
    this.noteAt,
    this.savedBy = MusingSavedBy.user,
  }) : createdAt = createdAt ?? DateTime.now();

  /// AI 收的时候你已经收过了（或反过来）——升成「一起收的」
  MusingEntry get sharedWith => MusingEntry(
    id: id,
    date: date,
    content: content,
    createdAt: createdAt,
    source: source,
    messageId: messageId,
    conversationId: conversationId,
    note: note,
    noteAt: noteAt,
    savedBy: MusingSavedBy.both,
  );

  /// 能不能跳回原文
  bool get canJumpBack => conversationId != null && messageId != null;

  /// 改备注。
  ///
  /// [note] 不传 = 不动；传 `null` = **清空**。
  ///
  /// 原来写的是 `note ?? this.note`，于是「把备注删掉」这件事做不到：调用方
  /// （musing_corner_screen）本来就是空字符串时传 null 表示清空，结果落到这里
  /// 被 `??` 吃掉，旧备注原地不动。用 [_unset] 哨兵把「没传」和「传了 null」
  /// 分开，两种意思才各归各的。
  ///
  /// [noteAt] 跟着 note 一起动，不单独传：备注变了就是刚写的，清空了就没有
  /// 时间可言。让调用方自己记得传时间，迟早有一处会忘。
  MusingEntry copyWith({Object? note = _unset}) {
    final changing = !identical(note, _unset);
    final nextNote = changing ? note as String? : this.note;
    return MusingEntry(
      id: id,
      date: date,
      content: content,
      createdAt: createdAt,
      source: source,
      messageId: messageId,
      conversationId: conversationId,
      note: nextNote,
      noteAt: changing ? (nextNote == null ? null : DateTime.now()) : noteAt,
      savedBy: savedBy,
    );
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
    'source': source.name,
    if (messageId != null) 'messageId': messageId,
    if (conversationId != null) 'conversationId': conversationId,
    if (note != null) 'note': note,
    if (noteAt != null) 'noteAt': noteAt!.toIso8601String(),
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
    noteAt: json['noteAt'] == null
        ? null
        : DateTime.tryParse(json['noteAt'] as String),
    savedBy: MusingSavedBy.values.firstWhere(
      (v) => v.name == json['savedBy'],
      orElse: () => MusingSavedBy.user,
    ),
  );
}
