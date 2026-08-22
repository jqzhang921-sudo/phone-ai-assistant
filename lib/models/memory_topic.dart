/// 一条长期记忆。**是一个「话题」，不是一条孤立的事实。**
///
/// 上一版（MemoryFact）是扁平的：一条一句话，每条都常驻上下文。问题是
/// 记得越多每轮越贵——32 条事实就是每轮 32 行，而且这个成本随记忆量线性涨。
///
/// 现在拆成两层，抄的是 Claude 自己那套 Memory 的结构：
///
/// - [summary] 一行，**常驻**。像「Cleo 的读书口味和书单」这样，说清这条讲什么。
/// - [details] 几条，**按需取**（open_memory）。真正的内容在这儿。
///
/// 于是 8 个话题的常驻成本大约 8 行，而每个话题底下可以挂十几条细节——
/// 记得越多，常驻成本几乎不涨。
///
/// ⚠️ 这和 2026-08-22 那次「退回全量索引」不矛盾，区别正在这里：那次是拿
/// **正文开头 40 字**当钩子，一句断掉的话看不出这条讲什么，白花钱；
/// [summary] 是**专门写的一句**，才是真钩子。当时的结论就是「真正的钩子得在
/// 写入时让模型自己写一句」——这就是那句话的落地。
library;

/// 分类是固定四类，不做自由标签。
///
/// 自由标签听起来更灵活，实际是把「该记成什么」整个丢给模型：同一件事这次
/// 记成「习惯」下次记成「日常」，攒几个月就是一团各说各话的标签。固定四类
/// 等于给它一个必须选边的框，选错了用户在记忆页里一眼看得出来。
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

/// 给模型看的短 id：uuid 去掉横杠取前 6 位。
///
/// 常驻上下文里每条都得带一个（不然它没法指名道姓地打开、改或删），
/// 全长 uuid 太占地方。工具按前缀匹配、撞了就拒绝并列候选——和 dairy-mcp 里
/// delete_diary 同一套做法，宁可让它多给几位，也不猜。
String shortTopicId(String id) => id.replaceAll('-', '').substring(0, 6);

/// 谁写的。用户问「这是你自己记的还是我说的」时要答得出来，
/// 记忆页上也要能一眼分开：它自己推断的和用户亲口说的，可信度不是一回事。
enum MemorySource { ai, user }

class MemoryTopic {
  final String id;
  final MemoryCategory category;

  /// 话题名。短，像个标题——「读书口味」「怎么称呼」。
  final String name;

  /// 一行摘要，**这一条唯一常驻上下文的部分**。
  ///
  /// 写的是「这条讲什么」，不是内容本身。它同时是钩子：模型靠它判断
  /// 该不该 open_memory 把细节取出来。写砸了这条记忆就等于不存在——
  /// 细节再全，它也想不到去打开。
  final String summary;

  /// 细节。按需取，不常驻。
  ///
  /// 一条一件事。两件挤一条里，改掉其中一件就得重写整条，删也删不干净。
  final List<String> details;

  final MemorySource source;

  /// 用户钉住的：模型不能改、不能删。
  ///
  /// 给的是一个**兜底**——自动写入总会写错，用户得有一个「这条不许动」的说法，
  /// 否则每次它改错都只能事后补救。可以钉在它自己写的条目上。
  final bool pinned;

  final DateTime createdAt;
  final DateTime updatedAt;

  MemoryTopic({
    required this.id,
    required this.category,
    required this.name,
    required this.summary,
    List<String>? details,
    this.source = MemorySource.ai,
    this.pinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : details = List.unmodifiable(details ?? const []),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  /// 改写。[updatedAt] 一定往前走——记忆页要靠它显示「改过」。
  ///
  /// [details] 是**整体替换**，不是追加。调用方（工具那边）要先读出来、
  /// 把要保留的一起写回去。做成替换而不是按下标增删，是因为下标操作在
  /// 模型手里几乎必然出错：它看到的列表和落盘的列表之间隔着一次往返。
  MemoryTopic copyWith({
    MemoryCategory? category,
    String? name,
    String? summary,
    List<String>? details,
    bool? pinned,
  }) => MemoryTopic(
    id: id,
    category: category ?? this.category,
    name: name ?? this.name,
    summary: summary ?? this.summary,
    details: details ?? this.details,
    source: source,
    pinned: pinned ?? this.pinned,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  bool get edited => updatedAt.difference(createdAt).inSeconds > 1;

  Map<String, dynamic> toJson() => {
    'id': id,
    'category': category.name,
    'name': name,
    'summary': summary,
    'details': details,
    'source': source.name,
    'pinned': pinned,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  /// 解析一律兜底，不抛。
  ///
  /// 备份文件可能来自更早或更新的版本，枚举里多出一个值就整个恢复失败，
  /// 代价远大于把那条落回默认分类。
  ///
  /// **兼容扁平版（MemoryFact）**：那一版只有 `content` 没有 name/summary/details，
  /// 上线到改版之间只隔了几个小时，真实数据大概率为零，但备份文件里可能有。
  /// 把 content 当 summary、name 留空由 UI 兜底，比整条丢掉强。
  factory MemoryTopic.fromJson(Map<String, dynamic> json) {
    final created =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    final legacyContent = json['content'] as String?;
    return MemoryTopic(
      id: json['id'] as String,
      category: MemoryCategory.values.firstWhere(
        (c) => c.name == json['category'],
        orElse: () => MemoryCategory.profile,
      ),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? json['name'] as String
          : '未命名',
      summary: (json['summary'] as String?) ?? legacyContent ?? '',
      details:
          (json['details'] as List?)?.map((e) => '$e').toList() ??
          // 扁平版的 why 不该丢：那是「为什么记这条」，放进细节里还有用
          [if ((json['why'] as String?)?.isNotEmpty == true) json['why'] as String],
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
