import '../models/book.dart';
import '../models/musing_entry.dart';
import 'storage_service.dart';

/// 索引本身也要有上限，否则「全部列出来」只是把问题推到一年以后。
/// 超出的部分不进上下文，靠 `recall_records` 按关键词翻。
///
/// 40 行 × 30 字 ≈ 1200 字，是能接受的常驻成本。眼下 16 条收藏 / 17 篇日记，
/// 离这个数还远——真撞上再谈按重要性排序，那时候才有得可排。
const _kMaxIndexed = 40;

/// 拼给聊天 system prompt 的上下文块。
///
/// 原来这里只塞最近 3 篇日记，于是整个 App 是**单向流水**：对话喂给日记、
/// 日记和收藏喂给信，但除了日记以外没有任何东西回流到对话。结果就是你刚写完
/// 一封信、它还亲手回了，转头到聊天里它完全不知道有这回事——因为信不在注入
/// 内容里；它连自己住在一个有信箱的 App 里都不知道。
///
/// 现在汇总四路：它住在哪儿、近期日记、被收藏的话、在读的书，外加通信状态。
///
/// ## 2026-08-22：从「取最近 n 条」改成「索引全部」
///
/// 在此之前每一路都是 `take(n)`——最近 n 条给全文，第 n+1 条往前的
/// **在它眼里根本不存在**。这不是「记不清」，是不知道有：`recall_records`
/// 要它自己先想到「我该翻一下」才会触发，可上下文里没有任何东西提示它
/// 有东西可翻。等于给了钥匙，没告诉它有门。
///
/// 现在每一条都占一行（日期 + 标签 + 摘要），只有最近几条给较全的正文。
/// 钩子全在，正文追问了再用 `recall_records` 取。
///
/// **代价说清楚：上下文是变大了，不是变小了。** 每多一条就多一行摘要，
/// 上限是 ([maxIndexed] - full) × 40 字 × 两节 ≈ 3000 字；按 16 条收藏 /
/// 17 篇日记算，眼下多出来约 1000 字。而且 memoryContext 挂在最后一条用户
/// 消息尾部（为了让 [人设][历史] 那段前缀逐字节稳定、吃得到 KV 缓存），
/// 所以这 800 字是**每轮都要重付的未命中部分**。
///
/// 认为值：换来的是它知道那 33 条记忆的存在。原来第 6 条往前的收藏，
/// 它连「有这么回事」都不知道，recall_records 那把钥匙也就没机会用上。
///
/// [fullDiaries] / [fullMusings] 是「给全文的条数」，不是「一共给几条」。
/// 一共给几条由 [maxIndexed] 封顶。
Future<String> buildMemoryContext({
  int fullDiaries = 3,
  int fullMusings = 5,
  int maxBooks = 5,
  int maxIndexed = _kMaxIndexed,
}) async {
  final buf = StringBuffer();

  buf.writeln(_whereYouLive);

  await _appendDiaries(buf, fullDiaries, maxIndexed);
  await _appendMusings(buf, fullMusings, maxIndexed);
  await _appendBooks(buf, maxBooks);
  await _appendLetterStatus(buf);

  buf.writeln(
    '以上都是你自己那边的记录，供你参考，不用背诵给用户听，也不要主动罗列。'
    '用户问起「记不记得」某件事时可以照上面如实回答。'
    '**上面列到、但只给了开头的那些，你知道有这条，但记不全原文**——'
    '要说到具体内容就用 recall_records 翻出来再答，'
    '翻到什么说什么，不要顺着那半句往下编。'
    '上面没有、也翻不到的，就说不记得。',
  );
  return buf.toString();
}

/// 它不知道自己住在什么地方——问起写信会反问「是那个开源项目里的 letter 吗」。
/// 这段成本极低，但直接决定它能不能接住用户提起的任何一个功能。
const _whereYouLive = '''
## 你在哪儿

你住在用户手机上的这个 App 里。除了聊天，这里还有几个地方：

- **书架**：用户收藏的书，可以单独就某本书或几本书和你讨论。
- **日记**：你用自己的口吻记下的日记，一天可以有几篇。
- **我想说 / 一隅**：首页那段你随口说的话；用户觉得值得留的会收藏进「一隅」。
- **信**：你和用户互相写信的地方，在「栖息」页。信是慢的，和聊天不一样。

用户提到这些名字时，指的就是这个 App 里的功能，不是别的产品。
''';

/// 日记：最近 [full] 篇给全文，更早的只留一行钩子。
///
/// 日记是它自己写的，「不知道自己写过」比「记不清写了什么」更糟——
/// 用户提起某天那篇，它会当作根本没有过这回事。所以宁可只给开头一句，
/// 也要让每一篇都在场。
Future<void> _appendDiaries(StringBuffer buf, int full, int maxIndexed) async {
  final entries = await StorageService.listDiaryEntries();
  if (entries.isEmpty) return;

  final listed = entries.take(maxIndexed).toList();
  buf.writeln('## 你写下的日记（共 ${entries.length} 篇）');
  for (var i = 0; i < listed.length; i++) {
    final e = listed[i];
    buf.writeln(
      i < full
          ? '- ${e.dateKey}：${e.content}'
          : '- ${e.dateKey}：${_hook(e.content, 40)}',
    );
  }
  if (listed.length > full) {
    buf.writeln('（最近 $full 篇是全文，其余只给了开头一句。）');
  }
  if (entries.length > listed.length) {
    buf.writeln(
      '（更早还有 ${entries.length - listed.length} 篇没列出来，'
      '用 recall_records 按关键词翻。）',
    );
  }
  buf.writeln();
}

/// 一隅里的收藏。**每条必须标清楚是谁说的、谁收的。**
///
/// 这里原来是一句写死的标题「你说过、被用户收藏的话」。收藏只有「我想说」
/// 一个来源时它是对的；等聊天里的收藏和自主收藏做出来之后，同一个列表里
/// 混进了「用户说的」和「你自己收的」，这个标题对其中一部分条目就成了假话。
///
/// 后果不是模型胡说，是它照着错标签复述——用户问「你收藏我说的话了吗」，
/// 它会把你在「我想说」写的句子说成是用户说的。喂进去的标签错了，
/// 输出不可能对。
///
/// 备注（[MusingEntry.note]）一并带上。那是用户长按手写的：愿意为一条收藏
/// 多打一行字，本身就是「这条对我不一样」的信号；而且备注写的往往是收藏时
/// 的由头，比正文更能让它接住话头。
Future<void> _appendMusings(StringBuffer buf, int full, int maxIndexed) async {
  final musings = await StorageService.listFavoritedMusings();
  if (musings.isEmpty) return;

  final listed = musings.take(maxIndexed).toList();
  buf.writeln('## 一隅里收藏的话（共 ${musings.length} 条）');
  buf.writeln(
    '（每条都标了是谁说的、谁收的，照标签说，别弄反。'
    '这些你都是看得到的，用户问起就直接聊，不要说自己看不到）',
  );
  for (var i = 0; i < listed.length; i++) {
    final m = listed[i];
    final note = m.note;
    buf.writeln(
      '- ${m.dateKey}｜${_saidBy(m)}｜${_savedBy(m)}：'
      '${i < full ? _clip(m.content, 80) : _hook(m.content, 40)}'
      '${note == null || note.isEmpty ? '' : '｜用户备注：${_clip(note, 30)}'}',
    );
  }
  if (listed.length > full) {
    buf.writeln('（最近 $full 条给到 80 字，其余只给了开头一句。）');
  }
  if (musings.length > listed.length) {
    buf.writeln(
      '（更早还有 ${musings.length - listed.length} 条没列出来，'
      '用 recall_records 按关键词翻。）',
    );
  }
  buf.writeln();
}

String _saidBy(MusingEntry m) => switch (m.source) {
  MusingSource.musing => '你在「我想说」写的',
  MusingSource.ai => '你在聊天里说的',
  MusingSource.user => '用户说的',
};

String _savedBy(MusingEntry m) => switch (m.savedBy) {
  MusingSavedBy.user => '用户收的',
  MusingSavedBy.ai => '你自己收的',
  MusingSavedBy.both => '你们各自都收了',
};

Future<void> _appendBooks(StringBuffer buf, int max) async {
  final books = await StorageService.listBooks();
  if (books.isEmpty) return;

  final reading =
      books.where((b) => b.status == ReadingStatus.reading).toList();
  final finished =
      books.where((b) => b.status == ReadingStatus.done).toList()..sort((a, b) {
        final at = a.finishedAt ?? a.createdAt;
        final bt = b.finishedAt ?? b.createdAt;
        return bt.compareTo(at);
      });

  if (reading.isEmpty && finished.isEmpty) return;

  buf.writeln('## 用户的书');
  if (reading.isNotEmpty) {
    buf.writeln('在读：${reading.take(max).map(_title).join('、')}');
  }
  if (finished.isNotEmpty) {
    buf.writeln('最近读完：${finished.take(3).map(_title).join('、')}');
  }
  buf.writeln();
}

/// 信只给**存在性**，不给内容。
///
/// 信的价值有一部分正来自它不在实时对话里——全文塞进聊天上下文，等于让聊天
/// 把信吃掉：用户在信里慢慢写的话，它在聊天里随时能引用，那个「慢」和距离感
/// 就没了。所以这里只让它知道「我们在通信、最后一封是谁写的、多久之前」，
/// 具体说了什么，让用户自己提。
///
/// ⚠️ 上面日记和收藏改成索引式之后，这一节**故意没跟着改**：信连一行钩子
/// 都不给，也不进 `recall_records`。不是漏了，是同一个理由的延续。
Future<void> _appendLetterStatus(StringBuffer buf) async {
  final letters = await StorageService.listLetters();
  if (letters.isEmpty) return;

  final latest = letters.first; // 已按时间倒序
  final unread = letters.where((l) => l.isFromAi && !l.read).length;
  final days = DateTime.now().difference(latest.createdAt).inDays;
  final whenText =
      days <= 0
          ? '今天'
          : days == 1
          ? '昨天'
          : '$days 天前';

  buf.writeln('## 通信');
  buf.writeln(
    '你和用户之间已经有 ${letters.length} 封往来，'
    '最近的一封是$whenText${latest.isFromAi ? '你写给 TA 的' : 'TA 写给你的'}。',
  );
  if (unread > 0) {
    buf.writeln('其中有 $unread 封你写的信 TA 还没拆开看。');
  }
  buf.writeln(
    '**只有信例外：你知道有这些信，但看不到里面写了什么**——信是慢的，'
    '内容留在信里。用户提起某封信时，顺着 TA 说的聊，不要假装记得原文，'
    '也不要凭空复述。',
  );
  // 这句是必须的：不划清界限，模型会把「信看不到」的框架顺手套到旁边几节上，
  // 明明日记和收藏的内容就摆在上面，它也会说「我看不到，得你翻给我看」。
  buf.writeln(
    '这条限制**只针对信**。上面日记、被收藏的话、书架里已经写出来的内容，'
    '你都是知道的，不要一并说成看不到。',
  );
  buf.writeln();
}

String _title(Book b) =>
    '《${b.title}》${b.author == null || b.author!.isEmpty ? '' : '（${b.author}）'}';

String _clip(String s, int max) {
  final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
}

/// 索引行用的截断：**优先切在句子边界上**。
///
/// 硬切的问题在实际渲染里很明显——「今天她提起想给 App 加记忆打分，我们聊了…」
/// 断在半句上，读起来像坏掉的数据，也没多给出信息。切到最近一个句号，
/// 至少是一句完整的话。
///
/// 只在句尾落在预算后半段时才用它：太靠前的句号（「好。」）切完等于没说，
/// 那还不如硬切拿满 [max] 个字的信息量。
///
/// ⚠️ 这仍然只是**正文开头**，不是「这条讲什么」的描述。真正的钩子得在写入时
/// 让模型自己写一句（像 Claude memory 的 frontmatter description 那样），
/// 那是下一步的事。别以为切得好看就等于索引好用了。
String _hook(String s, int max) {
  final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (oneLine.length <= max) return oneLine;

  final head = oneLine.substring(0, max);
  final end = head.lastIndexOf(RegExp(r'[。！？!?；;]'));
  if (end >= (max * 0.5).floor()) {
    return '${head.substring(0, end + 1)}…';
  }
  return '$head…';
}
