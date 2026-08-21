import '../models/book.dart';
import '../models/musing_entry.dart';
import 'storage_service.dart';

/// 拼给聊天 system prompt 的上下文块。
///
/// 原来这里只塞最近 3 篇日记，于是整个 App 是**单向流水**：对话喂给日记、
/// 日记和收藏喂给信，但除了日记以外没有任何东西回流到对话。结果就是你刚写完
/// 一封信、它还亲手回了，转头到聊天里它完全不知道有这回事——因为信不在注入
/// 内容里；它连自己住在一个有信箱的 App 里都不知道。
///
/// 现在汇总四路：它住在哪儿、近期日记、被收藏的话、在读的书，外加通信状态。
Future<String> buildMemoryContext({
  int maxDiaries = 3,
  int maxMusings = 5,
  int maxBooks = 5,
}) async {
  final buf = StringBuffer();

  buf.writeln(_whereYouLive);

  await _appendDiaries(buf, maxDiaries);
  await _appendMusings(buf, maxMusings);
  await _appendBooks(buf, maxBooks);
  await _appendLetterStatus(buf);

  buf.writeln(
    '以上都是你自己那边的记录，供你参考，不用背诵给用户听，也不要主动罗列。'
    '用户问起「记不记得」某件事时可以照上面如实回答；上面没有的就说不记得，'
    '不要编造。',
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

Future<void> _appendDiaries(StringBuffer buf, int max) async {
  final entries = await StorageService.listDiaryEntries();
  if (entries.isEmpty) return;
  buf.writeln('## 你写下的近期日记');
  for (final e in entries.take(max)) {
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
Future<void> _appendMusings(StringBuffer buf, int max) async {
  final musings = await StorageService.listFavoritedMusings();
  if (musings.isEmpty) return;
  buf.writeln('## 一隅里收藏的话');
  buf.writeln(
    '（每条都标了是谁说的、谁收的，照标签说，别弄反。'
    '下面这几条你是看得到的，用户问起就直接聊，不要说自己看不到）',
  );
  for (final m in musings.take(max)) {
    buf.writeln(
      '- ${m.dateKey}｜${_saidBy(m)}｜${_savedBy(m)}：'
      '${_clip(m.content, 80)}',
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
