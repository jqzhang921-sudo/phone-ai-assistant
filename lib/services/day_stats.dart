/// 「日子」的按天聚合。
///
/// 输入是四个 storage list API 的全量数据，输出是 `dateKey -> DayStats`
/// 的索引。构建是纯函数（[DayStatsIndex.build]），IO 只发生在
/// [DayStatsIndex.collect]：先拉全量，再交给 build——探索阶段结论是
/// storage 没有按天查询（SharedPreferences 是整串 JSON，对话是整文件），
/// 想看任何一天都必须读完整个文件，「按需加载」在这个存储形状下省不了解析，
/// 所以和 diary_generator / habitat 的 `_load` 一样：进屏一次全量读。
library;

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/diary_entry.dart';
import '../models/letter.dart';
import '../models/musing_entry.dart';
import '../utils/dates.dart' as dates;
import 'storage_service.dart';

/// 一天六个数字。纯值对象，零逻辑。
class DayStats {
  /// `YYYY-MM-DD`，与 DiaryEntry.dateKey 同契约。
  final String dateKey;

  /// 日记篇数。日记只属于 AI——用户不写，模型里也没有 role 字段可分。
  final int diaryCount;

  /// 用户写的信。
  final int userLetterCount;

  /// AI 写的信（= 主动 + 回信，拆开只是为给用户看）。
  final int aiLetterCount;

  /// AI 主动写的信（replyToId == null）。
  final int aiProactiveCount;

  /// AI 回的信（replyToId != null）。回信只按「落笔那天」计，
  /// 不解析它回的是哪封、那封是哪天写的。
  final int aiReplyCount;

  /// 用户消息。数的是「你来我往」的你这半。
  final int userMsgCount;

  /// AI 消息。系统主动说的话也是贴进对话的 assistant 消息（见
  /// storage_service 的注释），按 role 归入这一格——不算错。
  final int aiMsgCount;

  /// 一隅收藏条数。模型只有 [MusingEntry.date]（生成日），没有收藏时间戳，
  /// 按生成日计——与一隅页自己的口径一致，这是精度上限。
  final int musingCount;

  const DayStats({
    required this.dateKey,
    this.diaryCount = 0,
    this.userLetterCount = 0,
    this.aiLetterCount = 0,
    this.aiProactiveCount = 0,
    this.aiReplyCount = 0,
    this.userMsgCount = 0,
    this.aiMsgCount = 0,
    this.musingCount = 0,
  });

  /// 这一天有没有东西可讲。给月历格子打圆点用。
  bool get hasActivity =>
      diaryCount +
          userLetterCount +
          aiLetterCount +
          userMsgCount +
          aiMsgCount +
          musingCount >
      0;
}

/// 一天能装的东西。只给 build 内部当可变累加器用。
class _Counters {
  int diary = 0;
  int userLetter = 0;
  int aiProactive = 0;
  int aiReply = 0;
  int userMsg = 0;
  int aiMsg = 0;
  int musing = 0;
}

/// `dateKey -> DayStats` 的全量索引。build 一次后只读。
class DayStatsIndex {
  final Map<String, DayStats> _byDay;

  DayStatsIndex._(this._byDay);

  DayStats? statsFor(String dateKey) => _byDay[dateKey];

  /// 一条记录都没有。
  bool get isEmpty => _byDay.isEmpty;

  /// 有活动的天数有多少。
  int get activeDayCount => _byDay.length;

  /// 纯函数：喂数据出索引。构建全程无 IO、无时间线之外的状态——
  /// 单测只测这一层，IO 的问题交给 [[collect]]。
  factory DayStatsIndex.build({
    required List<Conversation> conversations,
    required List<DiaryEntry> diaries,
    required List<Letter> letters,
    required List<MusingEntry> musings,
  }) {
    final counters = <String, _Counters>{};
    _Counters of(String dateKey) =>
        counters.putIfAbsent(dateKey, _Counters.new);

    // 消息是最大的数据源，放第一个写——其余三个都是小题。
    //
    // 按每条消息自己的时间戳切日，不能按「对话今天更新过没」——
    // habitat 的「今天聊了多少」踩过这个坑（一段 538 条的老对话回一句，
    // 会显示 538 轮）。时间戳都是本地时间存本地时间读（ISO8601 无偏移），
    // 直接 y/m/d 判断，绝不做 toUtc 切日。
    for (final c in conversations) {
      for (final m in c.messages) {
        final role = m.role;
        if (role != MessageRole.user && role != MessageRole.assistant) {
          // system / toolCall / toolResult 不是「互发」的正文，不进数
          continue;
        }
        final s = of(dates.dateKeyOf(m.timestamp.toLocal()));
        if (role == MessageRole.user) {
          s.userMsg++;
        } else {
          s.aiMsg++;
        }
      }
    }

    for (final e in diaries) {
      of(e.dateKey).diary++;
    }

    for (final l in letters) {
      final s = of(l.dateKey);
      if (l.author == LetterAuthor.user) {
        s.userLetter++;
      } else {
        // null = 主动写，非 null = 回信（letter.dart 的约定）
        if (l.replyToId == null) {
          s.aiProactive++;
        } else {
          s.aiReply++;
        }
      }
    }

    for (final m in musings) {
      of(m.dateKey).musing++;
    }

    return DayStatsIndex._({
      for (final MapEntry(key: k, value: c) in counters.entries)
        k: DayStats(
          dateKey: k,
          diaryCount: c.diary,
          userLetterCount: c.userLetter,
          aiLetterCount: c.aiProactive + c.aiReply,
          aiProactiveCount: c.aiProactive,
          aiReplyCount: c.aiReply,
          userMsgCount: c.userMsg,
          aiMsgCount: c.aiMsg,
          musingCount: c.musing,
        ),
    });
  }

  /// IO 层：一次拉全量数据，再交给 [build]。
  ///
  /// 解析失败的对话会被 loadConversation 跳过（storage_service 计数落在
  /// `lastListFailures`），该对话的消息从统计中消失——与栖息页口径一致，
  /// 这里不做提示，避免过度工程。
  static Future<DayStatsIndex> collect() async {
    final conversations = await StorageService.listConversations();
    final diaries = await StorageService.listDiaryEntries();
    final letters = await StorageService.listLetters();
    final musings = await StorageService.listFavoritedMusings();
    return DayStatsIndex.build(
      conversations: conversations,
      diaries: diaries,
      letters: letters,
      musings: musings,
    );
  }
}

// TODO(性能)：对话量到「首开明显卡顿」时，给 StorageService 加一个只取
// `messages[].timestamp/role` 的轻量 API（jsonDecode 后不构造 ChatMessage，
// 省掉 base64 图片字符串拷贝）。现在和栖息页同量级，不值得第二套 decode 逻辑。
