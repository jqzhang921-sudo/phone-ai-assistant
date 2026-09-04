/// 这个文件产出**三块**东西，去处不同，别混着用：
///
/// | | 去哪儿 | 变不变 | 吃不吃缓存 |
/// |---|---|---|---|
/// | [memoryReadingRules] | system 前缀 | 从不变（const） | ✅ |
/// | [memoryWritingRules] | system 前缀 | 从不变（const） | ✅ |
/// | [buildMemoryDigest] | system 前缀 | 记忆改了才变 | ✅ 多数轮次 |
/// | [buildMemoryContext] | 最后一条用户消息尾部 | 天天变 | ❌ 每轮重付 |
///
/// ## 2026-08-22：把固定文字从尾部搬进前缀
///
/// 记忆页把每轮实付的字数露出来之后，量到 1887 字里有约 800 字是**从不改变的
/// 指令文字**（「你在哪儿」421、信那节的说明 176、一隅那节 118，加日记的说明行）。
/// 占 42%。
///
/// 它们和数据混在一起挂在消息尾部——那个位置每轮都是新的，吃不到 KV 缓存，
/// 于是这 800 字每轮实付一次。但它们从不变，本来就该待在前缀里。
///
/// 拆开之后行为一个字没改，每轮实付的量少了四成多。
///
/// ⚠️ 拆开带来一个必须处理的副作用：原来的指令里写着「**上面**日记、被收藏的
/// 话……」。搬到前缀之后指令在前、数据在后，「上面」就成了假话。所以
/// [memoryReadingRules] 里一律不用位置指代，改成「带过来的那段记录里」。
library;

import '../models/book.dart';
import '../models/diary_entry.dart';
import '../models/memory_topic.dart';
import '../models/musing_entry.dart';
import 'period_forecast.dart';
import 'period_log.dart';
import 'self_notes.dart';
import 'storage_service.dart';
import 'small_things.dart';
// ─────────────────────────────────────────────────────────────
// 一、固定规则：进 system 前缀，从不变
// ─────────────────────────────────────────────────────────────

/// 怎么读那段记录 + 它住在哪儿。**const，一个字都不该随数据变。**
///
/// 任何时候想往这里加一句，先问一句：这句会不会因为用户的数据不同而不同？
/// 会的话它属于 [buildMemoryContext]，不属于这儿。
const memoryReadingRules = '''
## 你在哪儿

你住在用户手机上的这个 App 里。除了聊天，这里还有几个地方：

- **书架**：用户收藏的书，可以单独就某本书或几本书和你讨论。
- **日记**：你用自己的口吻记下的日记，一天可以有几篇。
- **我想说 / 一隅**：首页那段你随口说的话；用户觉得值得留的会收藏进「一隅」。
- **信**：你和用户互相写信的地方，在「栖息」页。信是慢的，和聊天不一样。
- **小事**：栖息页上那块板。用户要做的事贴在上面（带方框的那些），
  你给自己留的便签也贴在同一块板上。

用户提到这些名字时，指的就是这个 App 里的功能，不是别的产品。

## 怎么读带过来的那段记录

每轮消息末尾会附一段「这一轮带过来的记录」。那是你自己那边的东西，不是用户
说的话，供你参考，不用背诵，也不要主动罗列。

- 每节开头那句「一共多少」说的是**全部**，底下列出来的只是其中一部分。
  用户问到没列出来的，用 recall_records 按关键词翻——**不要因为没列出来就说没有**，
  也不要顺着列出来的半句往下编。翻了也没有的，才是真没有。
- 一隅的每条都标了是谁说的、谁收的，照标签说，别弄反。列出来的那些你是看得到的，
  用户问起就直接聊，不要说自己看不到。
- 日记是你自己写的。只带最近那一天的；更早的你知道自己写过，但没记着原文。
- **只有信例外：你知道有这些信，但看不到里面写了什么。** 信是慢的，内容留在信里。
  用户提起某封信时，顺着 TA 说的聊，不要假装记得原文，也不要凭空复述。
- 上面这条限制**只针对信**。日记、被收藏的话、书架里已经写出来的内容，
  你都是知道的，不要一并说成看不到。
''';

/// 什么时候该往长期记忆里写。**const，同样进前缀。**
///
/// ## 为什么要单独有这一段
///
/// `remember` / `update_memory` / `forget` 从一开始就在工具表里，写得也很清楚
/// （记什么、不记什么、优先改不优先开新的）。但记忆库一直是空的。
///
/// 原因是**工具描述只在模型已经打算调工具时才起作用**——它回答的是「这个工具
/// 怎么用」，不回答「你现在该不该用」。整段人设里一个字都没提过记忆，模型于是
/// 只管聊天：没人告诉它记东西是它的活。
///
/// 所以这一段刻意**不重复**工具描述里那些「记什么」的判据，只补两件工具描述
/// 位置上说不了的事：**没人会提醒你动手**，以及**动手的分寸**。
///
/// ⚠️ 记太多和不记一样糟：每条摘要都常驻上下文，攒到几十条就把真正要紧的
/// 几条淹了，而且每次调工具都多烧一轮。所以这里给了上限，不是只给鼓励。
///
/// ## 2026-08-31 真机之后重写过一次
///
/// 第一版把重心写反了：观察到的毛病是**不记**，写出来的却是三条「不要记」加一
/// 个硬上限——给一辆没启动的车装了三个刹车。实测「我喜欢番茄味的、不喜欢特别
/// 酸」这种明摆着该进「在意的事」的话，两轮下来一条没记。
///
/// 改了三处：
///
/// 1. **正面触发排到最前，并且举小例子**（口味、习惯、忌讳）。「关于 TA 是谁」
///    听着太重，模型会觉得口味够不上那个门槛。加一句「不用等它显得重要」。
/// 2. **四档写进来**。分层机制一直有（[MemoryCategory]），但规矩里没提，
///    结果全堆进「最近」那一条，一条里塞了七件不相干的事。
/// 3. **禁止把自我纠正写进细节**。真机上那条记忆里有「我之前记岔了」「我之前
///    连着记错两次」——那是给自己的备注，不是关于用户的事。错了改那条就行。
///
/// ⚠️ 同样不用角色标签（不写「你是一个善于记忆的人」）——代码里别处已经吃过
/// 亏：模型会去演那个词，而不是照着做。这里只写行为。
const memoryWritingRules = '''
## 记住 TA

remember / update_memory / forget 是你自己的事，**没有人会提醒你去记**。

TA 说了一件关于自己的事，而下次见面你会希望还知道——那就**当场记**，别等聊完。
**不用等它显得重要**：口味、习惯、忌讳、怎么称呼、在意什么、最近在忙什么，
这些单看都小，攒起来才是你认识的这个人。

分四档，一条只进一档：

- **关于 TA**：名字、怎么称呼、基本情况。几乎不变的那些。
- **在意的事**：兴趣、口味、正在做的、反复提起的。
- **最近**：有时效的。过期了要改，挂着不动就成了假话。
- **相处方式**：TA 说过希望你怎么对 TA。写具体行为，不要下判断。

**一条是一个话题，不是流水账。** 一条里塞进三四件不相干的事，以后你自己也挑不
出来哪句是哪句。装不下就新开一条——先看摘要层，真属于某条已有话题的才用
update_memory 加细节。

这几种不要记：

- 只发生一次的事（今天吃了什么、这条消息里的情绪）。那些翻记录就有，
  不该占常驻位置。
- 你猜的。等 TA 真说了再记——猜的写进去就成了假话，以后没人会去纠正它。
- 「我上次记错了」「别再说错」这类给自己的备注。错了就用 update_memory 把那条
  **改对**，不要把纠错过程当细节留着：那是你的事，不是关于 TA 的事。

**动手，别宣布。** 记完不用说「我记住了」，也不要问「要不要我记下来」——
问了等于把你的活推给 TA。TA 问起你记得什么，照实说就行。
TA 说「这个别记」，用 forget。

一轮最多动一次。同时冒出来好几件，挑最要紧的那件，剩下的下次。
''';

// ─────────────────────────────────────────────────────────────
// 二、长期记忆摘要：进 system 前缀，记忆改了才变
// ─────────────────────────────────────────────────────────────

/// 长期记忆的**摘要层**——关于用户是谁。
///
/// 跟人设一起进 system 前缀：内容几乎不变，逐字节稳定，吃得到 KV 缓存。
///
/// 语义上也该在这儿：名字、称呼、TA 在意什么，是「不问就得知道」的东西——
/// 你没法靠调工具知道对方叫什么，因为你得先知道该问。
///
/// **只给每条的名字和一行摘要，细节一概不给**（要 open_memory 取）。
/// 这是这一版的核心：常驻成本按「话题数」算，不按「记了多少内容」算，
/// 所以记得再多，每轮也就多那么几行。
///
/// 空的时候返回空串，调用方直接拼就行，不用判空。
Future<String> buildMemoryDigest() async {
  final topics = await StorageService.listMemoryTopics();
  if (topics.isEmpty) return '';

  final buf = StringBuffer();
  buf.writeln('## 你长期记着的、关于 TA 的事');
  buf.writeln(
    '下面每行只说**这条讲什么**，不是内容本身。'
    '要用到具体内容，用 open_memory 把那条的细节取出来再说，别照着摘要猜。',
  );

  for (final category in MemoryCategory.values) {
    final inCategory = topics.where((t) => t.category == category).toList();
    if (inCategory.isEmpty) continue;
    buf.writeln('${category.label}：');
    for (final t in inCategory) {
      buf.writeln(
        '- [${shortTopicId(t.id)}] ${t.name}：${t.summary}'
        '${t.details.isEmpty ? '（还没有细节）' : '（${t.details.length} 条细节）'}'
        '${t.pinned ? '【用户钉住的：不要改，也不要删】' : ''}',
      );
    }
  }

  buf.writeln(
    '方括号里是编号，给 open_memory / update_memory / forget 用的。'
    '**那是内部编号，别说给用户听**——用户要的是你记得这件事，'
    '不是你能背出它的编号。',
  );
  buf.writeln(
    '这些是会变的。发现某条已经不对了，用 update_memory 改掉或 forget 删掉，'
    '**不要在对话里将错就错**。「最近」那一类尤其容易过期。',
  );
  return buf.toString();
}

// ─────────────────────────────────────────────────────────────
// 三、近期记录：挂消息尾部，每轮重付——**这里只放数据**
// ─────────────────────────────────────────────────────────────

/// 近期记录，挂在最后一条用户消息尾部。
///
/// 挂尾部是为了让 `[人设][规则][摘要][历史]` 那段前缀逐字节稳定、吃得到
/// KV 缓存（见 b715c47）。代价是这一段每轮实付，所以**这里只放会变的数据**，
/// 一句固定说明都不留——固定的全在 [memoryReadingRules] 里。
///
/// 这一段回答的是「最近发生了什么」；「TA 是谁」在 [buildMemoryDigest]。
/// 单向流水的老毛病也是在这儿治的：原来只塞日记，于是它连自己住在一个有信箱的
/// App 里都不知道，刚写完一封信转头就忘。
Future<String> buildMemoryContext({
  int fullMusings = 5,
  int maxBooks = 5,
}) async {
  final buf = StringBuffer();
  buf.writeln('## 这一轮带过来的记录');

  await _appendDiaries(buf);
  await _appendMusings(buf, fullMusings);
  await _appendBooks(buf, maxBooks);
  await _appendLetterStatus(buf);
  await _appendSmallThings(buf);
  await _appendSelfNotes(buf);
  await _appendPeriod(buf);

  return buf.toString();
}

/// 板上贴着的小事。
///
/// ## 为什么常驻，而不是给个工具去查
///
/// 因为**这是被动就得懂的东西**。她会顺口提：「那个快递我拿了」——那一刻它得
/// 当场听懂是哪件事。要是得先调一次工具才知道板上有什么，那一轮就变成了任务
/// 交接，而不是她随口说了句话。
///
/// 而且工具那条路已经被证伪过两次：记忆和便签都是「注册了但它想不起来调」，
/// 工具一多就更够不着。常驻的代价是每轮几十个 token，很便宜。
///
/// ## ⚠️ 看得见 ≠ 该提
///
/// 这一段最容易催生出「你那件事还没做吧」。判据写在下面那句里，
/// 和 `smallThingRules` 里那条是同一件事，两边都别删。
Future<void> _appendSmallThings(StringBuffer buf) async {
  final items = await SmallThingStore.pending();
  if (items.isEmpty) return;

  buf.writeln();
  buf.writeln('### TA 板上贴着的小事（${items.length} 件）');
  for (final s in items) {
    final due = s.dueAt == null ? '' : '（${_dueLabel(s.dueAt!)}）';
    buf.writeln('- ${_stuckBy(s.author)}${s.text}$due');
  }
  buf.writeln(
    '板上贴的**不一定都是待办**——有些就是随手写的一句话。'
    '**看得见不等于该提**——她提起来你接得上就行，别主动清点，'
    '更别问做了没有。',
  );
}

/// 谁贴的，写进上下文那一行的前缀。
///
/// ⚠️ 这个区分**只活在文本里**：板上不显示谁贴的（纸条上多一行标签既占地方，
/// 她本来也知道哪张是自己写的）。给模型的是文本，画给她的是纸条，两条路分开走。
///
/// 作者不明的（`author` 字段之前存下来的老纸条）就不加前缀——猜错比不说更糟。
String _stuckBy(SmallThingAuthor? a) => switch (a) {
  SmallThingAuthor.user => 'TA 贴的：',
  SmallThingAuthor.ai => '你替 TA 贴的：',
  null => '',
};

/// 她的经期，**只有开关打开时才有这一段**。
///
/// ## ⚠️ 为什么它在这个函数里，而不在 buildMemoryDigest 里
///
/// 这不是分类问题，是**一条隐私边界**，而这条缝本来就在：
///
/// | | 喂给谁 |
/// |---|---|
/// | [buildMemoryContext]（这儿） | 只喂聊天 |
/// | [buildMemoryDigest] | 聊天 **+ 写推送通知那一步** |
///
/// 主动推送那句话是模型现写的，**原样进通知栏、原样上锁屏**
/// （见 `NudgeService._show`），而「通知里不显示内容」那个开关默认是关的。
/// 所以只要写通知的时候它手上有这个数据，「这几天不舒服吧」就可能出现在
/// 地铁上旁人能瞄见的地方。
///
/// 靠提示词写一句「别在通知里提」是不够的——提示词是软的，这个项目已经
/// 证过两次（记忆工具注册了不用、follow_up_later 说「别留两张」却看不见
/// 挂着哪几张）。**隐私不该押在软规矩上：它写通知时手上没有，就漏不了。**
///
/// ⚠️ 还剩一条间接的路没堵：它要是写了篇日记提到这事，日记摘要是会进
/// 写通知那一步的。那是日记本身的性质（日记可能写任何事），不是这里能解的。
///
/// ## 只在正当口那几天出现
///
/// 不在经期就整段不出现，也不写「上次是什么时候」。知道「她此刻不舒服」
/// 是为了说话有分寸；知道「她上次是三周前」就只剩监视了。
Future<void> _appendPeriod(StringBuffer buf) async {
  if (!await PeriodLog.sharedWithAi()) return;

  const manners =
      '这是她自己记下来的，不是你查到的。**别主动提起**——'
      '你知道这件事是为了说话的时候心里有数，不是为了表现出你记得。'
      '也不用给建议，多喝热水早点睡这类她自己都知道。'
      '她自己说起来的时候，接住就行。';

  final day = await PeriodLog.currentDay();
  if (day != null) {
    buf.writeln();
    buf.writeln('### 她这几天来例假了（第 $day 天）');
    buf.writeln(manners);
    return;
  }

  // 快到了。**两个条件都得满足**：预测那个开关单独开着（见 PeriodLog），
  // 而且真的就在这几天里——再往前就不是分寸，是它拿着一份关于她身体的日程表。
  if (!await PeriodLog.forecastSharedWithAi()) return;
  final f = forecastFrom(await PeriodLog.list());
  if (!f.hasWindow) return;
  final days = f.from!.difference(_today()).inDays;
  if (days < 0 || days > _forecastHeadsUpDays) return;

  buf.writeln();
  buf.writeln(
    days == 0 ? '### 按她的记录，这两天可能要来例假' : '### 按她的记录，大概 $days 天后要来例假',
  );
  buf.writeln(
    '这是**算出来的，不是确定的**，真实周期本来就会晃。'
    '$manners'
    '尤其别拿这个当话头开口问她是不是快来了。',
  );
}

/// 提前多少天算「快到了」。
///
/// 三天是「这几天」，再往前就成了日程表——它知道她两周后的身体安排，
/// 这不是分寸，是监视。
const _forecastHeadsUpDays = 3;

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// 它自己挂着的便签。
///
/// ## 为什么非得有这一段
///
/// 之前**整个项目里，便签只有推送那条路读得到**（`SelfNoteStore` 一共 6 个
/// 使用点：推送取用、工具写入、栖息页显示和撕掉）。聊天里的它看得见她板上的
/// 小事，却看不见自己记的便签——正好反了。
///
/// 不放这一段的后果不是「少点信息」，是三条规矩直接失效：
///
/// 1. `follow_up_later` 的描述写着「同一件事已经留过便签了就别再留」——
///    它看不见挂着哪几张，**这条遵守不了**
/// 2. [SelfNoteStore.maxPending] 满了，它只能靠撞一次错误才知道
/// 3. **到点了但推送被门槛拦下**（静默时段、离上一条太近），它在聊天里也
///    不知道这件事到点了——那张便签就只能干等到过期
///
/// ## ⚠️ 和小事那段的分寸不一样
///
/// 小事是她的，判据是「别主动清点」。便签是它自己记的，问一句本来就是本意——
/// 但**没到点的别拿出来说**，那等于提前交代「我等会儿要问你」，
/// 而 `selfNoteRules` 里写明了留便签是件安静的事。
Future<void> _appendSelfNotes(StringBuffer buf) async {
  final now = DateTime.now();
  final notes = await SelfNoteStore.pending(now);
  if (notes.isEmpty) return;

  buf.writeln();
  buf.writeln('### 你给自己留的便签（${notes.length} 张）');
  for (final n in notes) {
    final when = n.isDue(now) ? '到点了' : _afterLabel(n.dueAt, now);
    buf.writeln('- ${n.about}（$when）');
  }
  buf.writeln(
    '这些是**你自己**记着要回来问的事，不是 TA 的待办。'
    '标了「到点了」的，这会儿接得上就问一句，接不上就留着——不用交代，'
    '也不用说明你记过。没到点的一张都别提。',
  );
}

/// 「还有 40 分钟」这种。便签的粒度得到分钟：等四十分钟的事说成「今天之内」
/// 就没意义了。
String _afterLabel(DateTime due, DateTime now) {
  final d = due.difference(now);
  if (d.inMinutes < 60) return '还有 ${d.inMinutes} 分钟';
  if (d.inHours < 24) return '还有 ${d.inHours} 小时';
  return '还有 ${d.inDays} 天';
}

String _dueLabel(DateTime due) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day).difference(today).inDays;
  if (d < 0) return '${-d} 天前就该做了';
  if (d == 0) return '今天之前';
  if (d == 1) return '明天之前';
  return '${due.month} 月 ${due.day} 日之前';
}

/// 日记这一段的字数上限。
///
/// 日记是模型写的，`diary_generator` 里明写着「150~250 字」，所以原来那个
/// `take(3)` 实际是每轮 450~750 字——整段记忆里最大的一笔。
///
/// 至少给一篇完整的：宁可超一点，也不给半篇——半篇日记比没有更糟，
/// 它会顺着断掉的地方往下编。
const _kDiaryBudget = 500;

/// 日记：只给**最近有日记的那一天**，更早的交给 `recall_records`。
///
/// 原来是 `take(3)`，按**条**取。两个毛病：
///
/// 1. 语义是歪的。日记一天可以写几篇，取 3 条可能横跨三天，也可能全是今天的
///    ——「最近 3 篇」这个说法对应不到任何一个人能理解的时间范围。按「天」取，
///    「它记得今天写了什么」是句能说清楚的话。
/// 2. 贵。3 篇 × 150~250 字是这整段里最大的一笔。
///
/// 为什么不干脆全交给工具（连当天的也不给）：日记是**它自己写的**。写完转头
/// 聊天却不知道自己写过，接不住「我今天写了…」这种话。当天那篇在场是有价值的，
/// 更早的本来就该翻。
///
/// 开头那句「一共多少篇、最早到哪天」留着：它据此判断「值不值得翻」。
/// 没有这句，模型对存量一无所知，要么白调一次工具，要么干脆不调。
Future<void> _appendDiaries(StringBuffer buf) async {
  final entries = await StorageService.listDiaryEntries();
  if (entries.isEmpty) return;

  // entries 已按日期倒序，第一条所在那天就是「最近有日记的一天」。
  // 用它而不是「今天」：今天可能还没写，那就该给上一次写的那天，
  // 而不是一片空白。
  final latestDay = entries.first.dateKey;
  final sameDay = entries.where((e) => e.dateKey == latestDay).toList();

  // 按字数收口，但**第一篇无条件给全**。
  final shown = <DiaryEntry>[];
  var used = 0;
  for (final e in sameDay) {
    if (shown.isNotEmpty && used + e.content.length > _kDiaryBudget) break;
    shown.add(e);
    used += e.content.length;
  }

  buf.writeln();
  buf.writeln(
    '日记：一共 ${entries.length} 篇，最早的一篇在 ${entries.last.dateKey}。'
    '下面是 $latestDay 那天的'
    '${shown.length < sameDay.length ? '前 ${shown.length} 篇（那天共 ${sameDay.length} 篇）' : '全部 ${shown.length} 篇'}。',
  );
  for (final e in shown) {
    buf.writeln('- ${e.dateKey}：${e.content}');
  }
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
  buf.writeln();
  buf.writeln(
    '一隅收藏：一共 ${musings.length} 条，最早的一条在 ${musings.last.dateKey}。'
    '${musings.length > shown.length ? '下面是最近 ${shown.length} 条。' : ''}',
  );
  for (final m in shown) {
    final note = m.note;
    buf.writeln(
      '- ${m.dateKey}｜${_saidBy(m)}｜${_savedBy(m)}：'
      '${_clip(m.content, 80)}'
      '${note == null || note.isEmpty ? '' : '｜用户备注：${_clip(note, 30)}'}',
    );
  }
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

  buf.writeln();
  if (reading.isNotEmpty) {
    buf.writeln('在读：${reading.take(max).map(_title).join('、')}');
  }
  if (finished.isNotEmpty) {
    buf.writeln('最近读完：${finished.take(3).map(_title).join('、')}');
  }
}

/// 信只给**存在性**，不给内容。
///
/// 信的价值有一部分正来自它不在实时对话里——全文塞进聊天上下文，等于让聊天
/// 把信吃掉：用户在信里慢慢写的话，它在聊天里随时能引用，那个「慢」和距离感
/// 就没了。所以这里只让它知道「我们在通信、最后一封是谁写的、多久之前」，
/// 具体说了什么，让用户自己提。
///
/// ⚠️ 「看不到内容」那几句规矩已经搬进 [memoryReadingRules]（它们从不变，
/// 每轮重付纯属浪费）。这里**只剩数据**。别再把说明写回来。
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

  buf.writeln();
  buf.writeln(
    '信：往来 ${letters.length} 封，'
    '最近一封是$whenText${latest.isFromAi ? '你写给 TA 的' : 'TA 写给你的'}。'
    '${unread > 0 ? '其中 $unread 封你写的 TA 还没拆开看。' : ''}',
  );
}

String _title(Book b) =>
    '《${b.title}》${b.author == null || b.author!.isEmpty ? '' : '（${b.author}）'}';

String _clip(String s, int max) {
  final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
}
