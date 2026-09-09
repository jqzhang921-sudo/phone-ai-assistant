/// 第三页上的一条东西。
///
/// 随笔和收藏共用一个模型，靠 [kind] 分。分成两个类会让「按时间混在一起看」
/// 变得很别扭——而那正是这一页最可能的看法：她想的是「我读书时留下的东西」，
/// 不是「我的随笔库」和「我的摘抄库」两个仓库。
enum ReadingNoteKind {
  /// 自己写的：读感、随笔、想到哪写到哪。
  essay,

  /// 摘下来的别人的话：书里的句子，可能从微信读书导入。
  quote,
}

class ReadingNote {
  final String id;
  final ReadingNoteKind kind;
  final String content;

  /// 摘录才有：这句话出自哪本。随笔可以不填。
  final String? bookTitle;

  /// 从微信读书导进来的标记。
  ///
  /// 需求里明写了「用户要有删除的选择」，所以导入的东西必须认得出来——
  /// 不然重复导入时既没法去重，也没法「只清掉导进来的、留下我自己写的」。
  final bool imported;

  final DateTime createdAt;

  const ReadingNote({
    required this.id,
    required this.kind,
    required this.content,
    this.bookTitle,
    this.imported = false,
    required this.createdAt,
  });

  ReadingNote copyWith({String? content, String? bookTitle}) => ReadingNote(
    id: id,
    kind: kind,
    content: content ?? this.content,
    bookTitle: bookTitle ?? this.bookTitle,
    imported: imported,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'content': content,
    if (bookTitle != null) 'bookTitle': bookTitle,
    if (imported) 'imported': true,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ReadingNote.fromJson(Map<String, dynamic> json) => ReadingNote(
    id: json['id'] as String,
    // 认不出来的一律当随笔，不抛。这一页是用户自己的东西，
    // 宁可显示一条格式怪的，也不能因为一条读不出来就整页空白。
    kind: ReadingNoteKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => ReadingNoteKind.essay,
    ),
    content: json['content'] as String? ?? '',
    bookTitle: json['bookTitle'] as String?,
    imported: json['imported'] == true,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );
}
