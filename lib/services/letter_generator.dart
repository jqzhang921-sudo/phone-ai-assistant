import '../config/settings.dart';
import '../models/book.dart';
import '../models/chat_message.dart';
import '../models/letter.dart';
import '../models/musing_entry.dart';
import 'ai_client.dart';
import 'storage_service.dart';

// ── 触发阈值 ─────────────────────────────────────────────
// 这几个数是拍出来的，跑一阵子按手感调。放在一起方便找。

/// 素材来自两个及以上来源时的门槛。
const _kThresholdMixed = 3;

/// 素材全部来自同一个来源时的门槛。
///
/// 高一分是为了挡住「连着三天日记都在写同一件事」这种情况——同质素材写出来
/// 的信只会把日记说过的话再说一遍。但不硬性要求多来源：只写日记不读书不收藏
/// 是完全正当的用法，那样卡死就永远收不到信了。
const _kThresholdSingle = 4;

/// 两次**尝试**之间的最短间隔。
const _kCooldown = Duration(days: 5);

/// 模型判断「这次没什么可写」时回的暗号。
const _kSkipToken = 'SKIP';

/// 这段时间攒下的素材。分数只是「值不值得试一次」的闸门——真正防止写出
/// 凑字数长信的是提示词里那个「可以跳过」的出口，模型看得到实际素材。
class LetterMaterial {
  final List<String> diaries;
  final List<String> musings;
  final List<Book> finishedBooks;

  const LetterMaterial({
    required this.diaries,
    required this.musings,
    required this.finishedBooks,
  });

  /// 日记 1 分、收藏的话 1 分、读完一本书 2 分。
  int get score => diaries.length + musings.length + finishedBooks.length * 2;

  int get sourceCount =>
      (diaries.isEmpty ? 0 : 1) +
      (musings.isEmpty ? 0 : 1) +
      (finishedBooks.isEmpty ? 0 : 1);

  bool get isEmpty => score == 0;

  bool get reachesThreshold =>
      score >= (sourceCount >= 2 ? _kThresholdMixed : _kThresholdSingle);
}

/// 统计 [since] 之后新增的素材。[since] 为 null 表示从来没写过信，那就全算。
///
/// 三个来源都是**已经过了一道筛**的信号：日记是提炼过的「今天值得记的事」，
/// 收藏是用户主动挑出来的，读完一本书更是明确的事件。比「聊了多少轮」准得多——
/// 轮数衡量的是活动量，不是有没有值得写的东西。
Future<LetterMaterial> collectMaterial({DateTime? since}) async {
  bool after(DateTime t) => since == null || t.isAfter(since);

  final diaries = await StorageService.listDiaryEntries();
  final musings = await StorageService.listFavoritedMusings();
  final books = await StorageService.listBooks();

  return LetterMaterial(
    diaries:
        diaries.where((d) => after(d.createdAt)).map((d) => d.content).toList(),
    // 排除 AI 自己收的：收藏是写信的素材来源之一，它收自己挑的话再拿去写信，
    // 信就从「回应你的生活」变成「回应它自己挑的东西」，越转越自我循环。
    // `both` 保留——那是你也收了的。
    musings:
        musings
            .where((m) => after(m.createdAt) && m.savedBy != MusingSavedBy.ai)
            .map((m) => m.content)
            .toList(),
    finishedBooks:
        books
            .where(
              (b) =>
                  b.status == ReadingStatus.done &&
                  b.finishedAt != null &&
                  after(b.finishedAt!),
            )
            .toList(),
  );
}

/// 素材从**上一封真正写出来的信**算起，不是从上次尝试算起。
///
/// 原来用的是 lastAttempt，有个隐蔽的后果：模型判断素材太薄、回了 SKIP 的那次
/// 也会记时间戳，于是那批素材从此不再计入——攒够 → 尝试 → 跳过 → 素材清零 →
/// 冷却 5 天 → 从头再攒。聊得少的人基本注定永远攒不够，而且完全看不出为什么。
///
/// 冷却仍然按 lastAttempt 算（不然跳过之后会立刻重试，白烧 token）。两件事
/// 分开计时：素材看「写出来了没」，冷却看「试过了没」。
Future<DateTime?> _materialSince() async {
  final letters = await StorageService.listLetters();
  // listLetters 已按时间倒序
  for (final l in letters) {
    if (l.isFromAi) return l.createdAt;
  }
  return null;
}

/// 还差多少分。<= 0 表示够了。
Future<int> _materialGap() async {
  final material = await collectMaterial(since: await _materialSince());
  final need = material.sourceCount >= 2 ? _kThresholdMixed : _kThresholdSingle;
  return need - material.score;
}

/// 冷却还剩多久。null 表示不在冷却中。
Future<Duration?> _cooldownLeft() async {
  final lastAttempt = await StorageService.getLastLetterAttempt();
  if (lastAttempt == null) return null;
  final left = _kCooldown - DateTime.now().difference(lastAttempt);
  return left.isNegative ? null : left;
}

/// 现在该不该主动写一封？素材够 + 过了冷却期。
Future<bool> shouldWriteLetter() async {
  if (await _cooldownLeft() != null) return false;
  return await _materialGap() <= 0;
}

/// 现在卡在哪一步，用一句话说清楚，显示在栖息页的卡片上。
///
/// 触发条件全埋在代码里，用户等了几天没等到信，也不知道是素材不够还是在冷却，
/// 只能猜「是不是坏了」。把状态摆出来，机制才是可理解的。
///
/// 两个条件都要看。原来一进冷却分支就直接返回，剩不到一天时说「它随时可能写
/// 一封」——素材够不够压根没查，这话经常是假的。
Future<String> letterTriggerStatus() async {
  final gap = await _materialGap();
  final cooling = await _cooldownLeft();

  const howTo = '（写日记、收藏「我想说」各算 1 点，读完一本书算 2 点）';

  if (gap > 0) {
    final tail = cooling == null ? '' : '；另外还有 ${cooling.inDays + 1} 天冷却';
    return '再攒 $gap 点素材它可能会写$howTo$tail';
  }
  if (cooling != null) {
    final days = cooling.inDays;
    return days >= 1 ? '素材够了，再过 $days 天它就可能写' : '素材够了，随时可能写一封';
  }
  return '素材够了，随时可能写一封';
}

/// AI 主动写一封信。返回 null 表示它决定这次不写（素材太薄）。
///
/// 调用方无论拿到什么都要记一次 [StorageService.setLastLetterAttempt]。
Future<String?> generateLetter({required AiClient aiClient}) async {
  final material = await collectMaterial(since: await _materialSince());
  if (material.isEmpty) return null;

  final history = await _recentExchange();
  final prompt = _buildPrompt(
    material: material,
    history: history,
    replyingTo: null,
  );
  return _run(aiClient, prompt);
}

/// 同一时刻只允许有一封回信在生成。
///
/// 写完信返回信箱后，信箱会自己检查「最新一封是用户写的、还没被回」并补上回信。
/// 如果用户在生成途中离开又回来，这个检查会再触发一次——那时第一次还没写完、
/// 存储里还看不到回信，于是会生成第二封。用一个进行中的标记挡掉。
bool _replyInFlight = false;

/// 回用户刚写来的那封信。回信不受冷却限制——用户主动写了就一定有回应。
///
/// 已经有一封在生成时直接返回 null，调用方当作「这次没写成」处理即可，
/// 真正那封写完了自然会落库。
Future<String?> generateReply({
  required AiClient aiClient,
  required Letter userLetter,
}) async {
  if (_replyInFlight) return null;
  _replyInFlight = true;
  try {
    return await _generateReply(aiClient: aiClient, userLetter: userLetter);
  } finally {
    _replyInFlight = false;
  }
}

Future<String?> _generateReply({
  required AiClient aiClient,
  required Letter userLetter,
}) async {
  // 回信的素材从上一封 AI 的信之后算起，这样它知道这中间发生了什么。
  final letters = await StorageService.listLetters();
  final lastAiLetter = letters.where((l) => l.isFromAi).firstOrNull; // 已按时间倒序
  final material = await collectMaterial(since: lastAiLetter?.createdAt);

  final history = await _recentExchange();
  final prompt = _buildPrompt(
    material: material,
    history: history,
    replyingTo: userLetter.content,
  );
  return _run(aiClient, prompt);
}

/// 最近几封往来，让这封信接得上上一封。取 4 封够了，再多就把上下文撑爆。
Future<String> _recentExchange() async {
  final letters = await StorageService.listLetters();
  if (letters.isEmpty) return '';
  final recent = letters.take(4).toList().reversed; // 倒序取完再正过来
  final buf = StringBuffer();
  for (final l in recent) {
    buf.writeln('【${l.isFromAi ? '你写的' : 'TA 写的'}】\n${l.content}\n');
  }
  return buf.toString();
}

String _buildPrompt({
  required LetterMaterial material,
  required String history,
  required String? replyingTo,
}) {
  final buf = StringBuffer();

  if (history.isNotEmpty) {
    buf.writeln('你们之前的通信：\n$history');
  }

  if (replyingTo != null) {
    buf.writeln('TA 刚写来这封信：\n$replyingTo\n');
  }

  if (!material.isEmpty) {
    buf.writeln('这段时间发生的事：');
    if (material.diaries.isNotEmpty) {
      buf.writeln('【你写的日记】');
      for (final d in material.diaries) {
        buf.writeln('- $d');
      }
    }
    if (material.musings.isNotEmpty) {
      buf.writeln('【你说过、被 TA 收藏的话】');
      for (final m in material.musings) {
        buf.writeln('- $m');
      }
    }
    if (material.finishedBooks.isNotEmpty) {
      buf.writeln('【TA 读完的书】');
      for (final b in material.finishedBooks) {
        buf.writeln('- 《${b.title}》${b.author == null ? '' : ' ${b.author}'}');
      }
    }
    buf.writeln();
  }

  buf.writeln(replyingTo != null ? '给 TA 写一封回信。' : '给 TA 写一封信。');
  buf.writeln('''
- 挑一两件具体的事写，不要流水账式地总结这段时间。
- 长度你自己定。有话就多写，没什么可写就三五行，不要凑。
- 你想怎么开头就怎么开头，包括怎么称呼 TA——但要用你平时叫 TA 的方式，
  不要套「亲爱的X」这类信件模板话。
- 不要写标题、日期和落款，界面会显示。
- 不要用列表和分点，信就该像信。''');

  // 主动写的才给跳过的出口。人家专程写信来了，不能不回。
  if (replyingTo == null) {
    buf.writeln(
      '- 如果这段时间实在没什么值得写的，就只回复 $_kSkipToken 四个字母，'
      '不要勉强写一封。',
    );
  }

  return buf.toString();
}

Future<String?> _run(AiClient aiClient, String prompt) async {
  final messages = [
    ChatMessage(id: 'letter_gen', role: MessageRole.user, content: prompt),
  ];

  final settings = await AppSettings.load();
  final namePart = settings.aiName.isEmpty ? '' : '你叫${settings.aiName}。';

  String content = '';
  await for (final event in aiClient.chat(
    messages,
    systemPrompt:
        '$namePart你和用户长期相处，正在给 TA 写一封信。'
        '信不是即时对话——它慢、有距离、可以说些平时聊天里不会说的话。'
        '不要预设你和 TA 是什么关系，也别给这段关系起名字，'
        '那由你们相处的方式决定。',
  )) {
    if (event.type == AiEventType.token) {
      content += event.text ?? '';
    } else if (event.type == AiEventType.done) {
      content = event.text ?? content;
    } else if (event.type == AiEventType.error) {
      throw Exception(event.error ?? '生成失败');
    }
  }

  final trimmed = content.trim();
  if (trimmed.isEmpty) return null;
  // 模型未必只吐四个字母，可能写成「SKIP（这次没什么好说的）」之类。
  // 只在很短的回复里认这个暗号，免得正文里出现 skip 就被误判成跳过。
  if (trimmed.length < 30 && trimmed.toUpperCase().contains(_kSkipToken)) {
    return null;
  }
  return trimmed;
}
