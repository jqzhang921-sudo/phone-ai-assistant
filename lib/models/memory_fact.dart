/// 一条「稳定事实」——关于用户是谁，不是某天发生了什么。
///
/// 为什么要有这一层：在此之前，App 的记忆全是**近期产出物**（最近几篇日记、
/// 最近几条收藏、书、信），全都在回答「某天发生了什么」。没有任何一层在回答
/// 「TA 是谁」。后果在新开一个对话时最明显——没有历史可推，它连该怎么称呼
/// 用户都不知道。
///
/// 划线的原则是：**需要「不问就知道」的进上下文，需要「问了才翻」的进工具。**
/// 名字、称呼、TA 在意什么、TA 不喜欢被怎么对待 → 常驻；某天说过的某句话 →
/// `recall_records`。你没法靠调工具知道对方叫什么，因为你得先知道该问。
///
/// 而且这一层几乎不变，能跟人设一起待在**吃得到 KV 缓存的前缀**里，
/// 比挂在消息尾部的近期记录还便宜。
library;

/// 分类是固定四类，不做自由标签。
///
/// 自由标签听起来更灵活，实际是把「该记成什么」这个判断整个丢给模型：
/// 同一件事这次记成「习惯」下次记成「日常」，攒几个月就是一团各说各话的标签。
/// 固定四类等于给它一个必须选边的框，选错了用户在记忆页里一眼看得出来。
enum MemoryCategory {
  /// 名字、怎么称呼、基本情况。最稳定的一档，几乎不该变。
  profile,

  /// 在意的事：兴趣、正在做的、反复提起的。
  interest,

  /// 近期状况。**唯一有时效的一档**——过一阵子就该被改写或删掉，
  /// 留着不动会变成假话（「最近在准备考试」考完两个月还挂着）。
  recent,

  /// 相处方式：TA 说过希望你怎么对 TA。
  ///
  /// 这一档最容易写坏。记「TA 不喜欢被哄」是有用的；记「TA 是个理性的人」
  /// 就是给模型一个角色标签，它会去演那个词——和 chat_screen 里
  /// 「不给这段关系起名字」踩的是同一个坑。所以描述**具体行为**，不下判断。
  rapport,
}

extension MemoryCategoryLabel on MemoryCategory {
  String get label => switch (this) {
    MemoryCategory.profile => '关于 TA',
    MemoryCategory.interest => '在意的事',
    MemoryCategory.recent => '最近',
    MemoryCategory.rapport => '相处方式',
  };

  /// 给模型看的说明，直接进工具的 schema。
  String get hint => switch (this) {
    MemoryCategory.profile => '名字、怎么称呼 TA、基本情况。几乎不变的那些。',
    MemoryCategory.interest => '在意的事：兴趣、正在做的事、反复提起的东西。',
    MemoryCategory.recent => '近期状况。会过期——过时了要改写或删掉，别留着变成假话。',
    MemoryCategory.rapport =>
      'TA 说过希望你怎么对 TA。写具体行为（「不喜欢被反问」），'
          '不要写性格判断（「是个理性的人」）——那是标签，你会去演它。',
  };
}

/// 谁写的。用户问「这是你自己记的还是我说的」时要答得出来，
/// 记忆页上也要能一眼分开：它自己推断的和用户亲口说的，可信度不是一回事。
enum MemorySource { ai, user }

class MemoryFact {
  final String id;
  final MemoryCategory category;

  /// 一句话。**一条只记一件事**——两件事挤在一条里，改掉其中一件就得重写整条，
  /// 删也删不干净。
  final String content;

  /// 为什么记这条 / 从哪儿听来的。
  ///
  /// 不是装饰。三个月后用户在记忆页看到一条不认识的事实，没有这句就只能猜
  /// 它是不是编的；模型自己回看时，也是靠这句判断该不该改写。
  final String? why;

  final MemorySource source;

  /// 用户钉住的：模型不能改、不能删。
  ///
  /// 给的是一个**兜底**——自动写入总会写错，用户得有一个「这条不许动」的说法，
  /// 否则每次它改错都只能事后补救。可以钉在它自己写的条目上。
  final bool pinned;

  final DateTime createdAt;
  final DateTime updatedAt;

  MemoryFact({
    required this.id,
    required this.category,
    required this.content,
    this.why,
    this.source = MemorySource.ai,
    this.pinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  /// 改写。[updatedAt] 一定往前走——记忆页要靠它显示「改过」。
  MemoryFact copyWith({
    MemoryCategory? category,
    String? content,
    String? why,
    bool? pinned,
  }) => MemoryFact(
    id: id,
    category: category ?? this.category,
    content: content ?? this.content,
    why: why ?? this.why,
    source: source,
    pinned: pinned ?? this.pinned,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  bool get edited => updatedAt.difference(createdAt).inSeconds > 1;

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.name,
    'content': content,
    if (why != null) 'why': why,
    'source': source.name,
    'pinned': pinned,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// 解析一律兜底，不抛。
  ///
  /// 备份文件可能来自更早或更新的版本，枚举里多出一个值就整个恢复失败，
  /// 代价远大于把那条落回默认分类。这和 [MusingEntry] 里 source/savedBy
  /// 的处理是同一个理由。
  factory MemoryFact.fromJson(Map<String, dynamic> json) {
    final created =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    return MemoryFact(
      id: json['id'] as String,
      category: MemoryCategory.values.firstWhere(
        (c) => c.name == json['category'],
        orElse: () => MemoryCategory.profile,
      ),
      content: json['content'] as String? ?? '',
      why: json['why'] as String?,
      source: MemorySource.values.firstWhere(
        (s) => s.name == json['source'],
        orElse: () => MemorySource.ai,
      ),
      pinned: json['pinned'] as bool? ?? false,
      createdAt: created,
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? created,
    );
  }
}
