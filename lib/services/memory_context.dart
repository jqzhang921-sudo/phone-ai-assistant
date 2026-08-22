import '../models/book.dart';
import '../models/memory_fact.dart';
import '../models/musing_entry.dart';
import 'storage_service.dart';

/// 「稳定事实」块——关于用户是谁。**去处和 [buildMemoryContext] 不一样，
/// 这是这两个函数唯一重要的区别，别把它们拼到一起。**
///
/// - 这一块跟人设一起进 **system 前缀**：内容几乎不变，逐字节稳定，吃得到
///   KV 缓存，每轮几乎不额外付钱。
/// - [buildMemoryContext] 挂在**最后一条用户消息尾部**：内容天天变，放前面
///   会把后面几千 token 的历史挤出缓存（见 b715c47）。
///
/// 分开的理由不只是缓存，还有语义：名字、称呼、TA 在意什么，是「不问就得知道」
/// 的东西——你没法靠调工具知道对方叫什么，因为你得先知道该问。而某天说过的
/// 某句话是「问了才翻」的，交给 `recall_records`。
///
/// 空的时候返回空串，调用方直接拼就行，不用判空。
Future<String> buildStableFacts() async {
  final facts = await StorageService.listMemoryFacts();
  if (facts.isEmpty) return '';

  final buf = StringBuffer();
  buf.writeln('## 你知道的关于 TA 的事');
  buf.writeln(
    '（这些是你长期记着的，不是这次对话里冒出来的。'
    '用来接住话头，不要主动罗列，也不要拿它去证明你记得。）',
  );

  for (final category in MemoryCategory.values) {
    final inCategory = facts.where((f) => f.category == category).toList();
    if (inCategory.isEmpty) continue;
    buf.writeln('${category.label}：');
    for (final f in inCategory) {
      // why 一并给出来：模型改写这条时要靠它判断该不该动
      // （比如「她说的」和「我猜的」，前者不该被自己推翻）。
      final why = f.why;
      buf.writeln(
        '- [${shortFactId(f.id)}] ${f.content}'
        '${why == null || why.isEmpty ? '' : '（${_clip(why, 40)}）'}'
        '${f.pinned ? '【用户钉住的：不要改，也不要删】' : ''}',
      );
    }
  }

  buf.writeln(
    '方括号里是每条的编号，给 update_memory / forget 用的。'
    '**那是内部编号，别说给用户听**——用户要的是你记得这件事，'
    '不是你能背出它的编号。',
  );
  buf.writeln(
    '这些是会变的。发现某条已经不对了，用 update_memory 改掉或 forget 删掉，'
    '**不要在对话里将错就错**。「最近」那一类尤其容易过期。',
  );
  return buf.toString();
}

/// 拼给聊天 system prompt 的上下文块。
///
/// 原来这里只塞最近 3 篇日记，于是整个 App 是**单向流水**：对话喂给日记、
/// 日记和收藏喂给信，但除了日记以外没有任何东西回流到对话。结果就是你刚写完
/// 一封信、它还亲手回了，转头到聊天里它完全不知道有这回事——因为信不在注入
/// 内容里；它连自己住在一个有信箱的 App 里都不知道。
///
/// 现在汇总四路：它住在哪儿、近期日记、被收藏的话、在读的书，外加通信状态。
///
/// ## 2026-08-22：试过「索引全部」，退回「只给形状」
///
/// 中间版本把每一条收藏 / 每一篇日记都列成一行进上下文，理由是「不这样它
/// 不知道有东西可翻」。**这个理由不成立**——`recall_records` 的工具描述本身
/// 就一直在上下文里，而且明写了「用户问起更早的⋯用这个查」。门上早有牌子。
///
/// 去掉那个错理由之后，全量索引真正多买到的只有两件事：模型能在上下文里做
/// 语义匹配（recall 是字面子串匹配，搜「工作」找不到写着「上班」的那条），
/// 以及它可能在用户没问时主动提起。两件都是真的，但在 16 条收藏 / 17 篇日记
/// 这个量级上，不值每轮多背 1000 字——`recall_records` 一次调用就能全捞回来。
///
/// 现在只给**形状**：一共多少条、最早到什么时候、最近几条的正文。
/// 它据此判断值不值得翻，剩下交给工具。
///
/// 什么时候该重新考虑全量索引：条目多到 recall 一次捞不完，或者「主动想起」
/// 变成明确想要的效果。那时候要一并解决索引行的质量问题——正文开头不是
/// 「这条讲什么」，真正的钩子得在写入时让模型自己写一句。
Future<String> buildMemoryContext({
  int fullDiaries = 3,
  int fullMusings = 5,
  int maxBooks = 5,
}) async {
  final buf = StringBuffer();

  buf.writeln(_whereYouLive);

  await _appendDiaries(buf, fullDiaries);
  await _appendMusings(buf, fullMusings);
  await _appendBooks(buf, maxBooks);
  await _appendLetterStatus(buf);

  buf.writeln(
    '以上都是你自己那边的记录，供你参考，不用背诵给用户听，也不要主动罗列。'
    '用户问起「记不记得」某件事时，照上面如实回答。'
    '**每节开头那句「一共多少条」是全部，下面列出来的只是最近几条。**'
    '用户问到更早的、或者收藏正文被截断了（末尾有 …），'
    '用 recall_records 翻出来再答——翻到什么说什么，'
    '不要顺着列出来的那半句往下编，也不要因为没列出来就说没有。'
    '翻了也没有的，才是真没有。',
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

/// 日记：只给形状 + 最近 [full] 篇全文。
///
/// 形状那一行（共几篇、最早到哪天）是刻意留的：它据此判断「值不值得翻」。
/// 没有这行，模型对存量一无所知，要么白调一次工具，要么干脆不调。
/// 一行的成本换掉一次无谓的工具往返，划算。
Future<void> _appendDiaries(StringBuffer buf, int full) async {
  final entries = await StorageService.listDiaryEntries();
  if (entries.isEmpty) return;

  final shown = entries.take(full).toList();
  buf.writeln('## 你写下的日记');
  buf.writeln(
    '一共 ${entries.length} 篇，最早的一篇在 ${entries.last.dateKey}。'
    '${entries.length > shown.length ? '下面只有最近 ${shown.length} 篇的全文，'
        '更早的用 recall_records 按关键词翻——你知道有，但没记着原文。' : ''}',
  );
  for (final e in shown) {
    buf.writeln('- ${e.dateKey}：${e.content}');
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
Future<void> _appendMusings(StringBuffer buf, int full) async {
  final musings = await StorageService.listFavoritedMusings();
  if (musings.isEmpty) return;

  final shown = musings.take(full).toList();
  buf.writeln('## 一隅里收藏的话');
  buf.writeln(
    '一共 ${musings.length} 条，最早的一条在 ${musings.last.dateKey}。'
    '${musings.length > shown.length ? '下面只有最近 ${shown.length} 条，'
        '更早的用 recall_records 翻。' : ''}'
    '（每条都标了是谁说的、谁收的，照标签说，别弄反。'
    '列出来的这些你是看得到的，用户问起就直接聊，不要说自己看不到）',
  );
  for (final m in shown) {
    final note = m.note;
    buf.writeln(
      '- ${m.dateKey}｜${_saidBy(m)}｜${_savedBy(m)}：'
      '${_clip(m.content, 80)}'
      '${note == null || note.isEmpty ? '' : '｜用户备注：${_clip(note, 30)}'}',
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
/// ⚠️ 日记和收藏至少给了「一共多少条」这个形状，这一节**故意连形状都不给**
/// 内容：只说有几封、谁写的、多久之前，不给任何一句正文，也不进
/// `recall_records`。不是漏了，是同一个理由的延续。
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
