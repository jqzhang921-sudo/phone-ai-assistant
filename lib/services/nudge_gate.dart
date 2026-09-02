/// 主动推送的门槛。
///
/// ## 这一层只回答「现在能不能说话」
///
/// 「有没有值得说的」是另一件事，交给生成那一步（模型可以回「没有」，那就不推）。
/// 两件事分开，是因为它们的失败方式不一样：
///
/// - 门槛判错 → **打扰**。半夜响、一天响五次，这种错误一次就够让人关掉推送。
/// - 内容判错 → 无聊。烦，但不至于卸载。
///
/// 所以门槛做成纯函数，不联网、不调模型、可以直接测；而且它先跑——**过不了门槛
/// 就根本不调模型**，省钱也省得模型每次都想说话。
///
/// ## ⚠️ 这里没有「太久没聊就推」这一条，是故意的
///
/// 那是最顺手的触发器，也是这类 App 最后都变得让人烦的原因：它拿愧疚换打开率。
/// 定下的规矩是**推送要带来一件东西，不能索取一件东西**——
/// 「刚写完一封信」可以，「好久没见你了」不行。
///
/// 所以「隔了多久没聊」在这里只用来**拦**（刚聊完就别推），不用来**催**。
library;

/// ⚠️ 这里**没有「一天最多几条」**，是想清楚之后拿掉的。
///
/// 配额会倒过来变成产出指标：今天还剩两条没用，那就凑两条出来。和「每天必须
/// 收藏一条」是同一个毛病——**规定了产出**。而要的是产出发生的时候有地方去。
///
/// 频率由**有没有事情发生**决定（见 `NudgeService.collectCandidates`）：
/// 他写完一封信、记了一篇日记，那才是他想开口的时候。没发生就没有，
/// 不需要一个数字来限制。
///
/// ⚠️ 这里也**没有一天几条的上限**了，2026-09-02 删掉的。
///
/// 它本来是「防某个 bug 连环推送」的保险丝，可 [NudgePrefs.minGapBetweenNudges]
/// 已经把这件事做了：一小时一条，加上静默时段，一天上限本来就只有十几条，
/// 而真实候选一天也就一两个。两道闸防同一件事，多的那道只会误伤。
///
/// 实际就误伤了：静默写入（`runOnStartup`）当时也在计数，一天装九次包就把
/// 四条额度耗光，真该弹通知的时候保险丝已经断了。计数那个 bug 单独修了，
/// 但这道闸本身也该拆——**它拦得住的东西，间隔那道全都拦得住**。

/// 用户能调的东西。只剩两样，因为只有这两样是**你的**偏好，
/// 其余都该由「发生了什么」决定。
class NudgePrefs {
  final bool enabled;

  /// 静默时段，闭开区间 [start, end)，按小时。默认 23:00–08:00，跨零点。
  ///
  /// 这一条留着不是给他立规矩，是你的作息。
  final int quietStartHour;
  final int quietEndHour;

  /// 两条推送之间至少隔多久。
  ///
  /// 从 4 小时降到 1 小时：4 小时是配额那版的遗留——那会儿每次唤醒都问模型
  /// 「你想说点什么吗」，它每次都想说，所以必须有个东西压着。现在压频率的是
  /// 「有没有事情发生」，这条只剩防连环触发的作用，1 小时够了。
  final Duration minGapBetweenNudges;

  /// 便签到点时用的间隔。
  ///
  /// 两张便签可能只差二十分钟到点（她说完「我去做饭」又说「等会儿要出门」）。
  /// 拿一小时去卡，第二张必然过期——而那两件事是分开的，都值得问。
  final Duration minGapAfterFollowUp;

  /// 最后一次聊天之后至少静默多久才考虑推。
  ///
  /// 从 3 小时降到 1 小时：3 小时这个数没考虑到——如果她本来就聊得勤，
  /// 一整天很难攒出连续 3 小时不碰这个 App 的空档，普通推送（非便签）会
  /// 一直被 [NudgeBlock.tooSoonAfterChat] 拦住，实测确认过。
  ///
  /// 降到 1 小时之后，真正防打扰的还是 [minGapBetweenNudges] 和
  /// 静默时段那两道——这条只用来确保"不是话音刚落就立刻插一句"，
  /// 不需要单独扛住全部的打扰风险。
  ///
  /// ⚠️ **便签不受这条约束**，见 [decideNudge]。
  final Duration minSilenceAfterChat;

  const NudgePrefs({
    this.enabled = false,
    this.quietStartHour = 23,
    this.quietEndHour = 8,
    this.minGapBetweenNudges = const Duration(hours: 1),
    this.minGapAfterFollowUp = const Duration(minutes: 20),
    this.minSilenceAfterChat = const Duration(hours: 1),
  });

  NudgePrefs copyWith({
    bool? enabled,
    int? quietStartHour,
    int? quietEndHour,
  }) => NudgePrefs(
    enabled: enabled ?? this.enabled,
    quietStartHour: quietStartHour ?? this.quietStartHour,
    quietEndHour: quietEndHour ?? this.quietEndHour,
    minGapBetweenNudges: minGapBetweenNudges,
    minGapAfterFollowUp: minGapAfterFollowUp,
    minSilenceAfterChat: minSilenceAfterChat,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'quietStartHour': quietStartHour,
    'quietEndHour': quietEndHour,
  };

  factory NudgePrefs.fromJson(Map<String, dynamic> json) => NudgePrefs(
    enabled: json['enabled'] as bool? ?? false,
    quietStartHour: json['quietStartHour'] as int? ?? 23,
    quietEndHour: json['quietEndHour'] as int? ?? 8,
  );
}

/// 没推成的话，是被哪一条拦下的。
///
/// 每一条都要能说清楚——设置页那个「现在试一次」要把原因原样显示出来，
/// 否则用户点了没反应，只会以为功能坏了。
enum NudgeBlock {
  none,
  disabled,
  quietHours,
  tooSoonAfterNudge,
  tooSoonAfterChat,
}

extension NudgeBlockLabel on NudgeBlock {
  String get label => switch (this) {
    NudgeBlock.none => '可以推',
    NudgeBlock.disabled => '主动说话没开',
    NudgeBlock.quietHours => '在你设的不打扰时段里',
    NudgeBlock.tooSoonAfterNudge => '离上一条太近',
    NudgeBlock.tooSoonAfterChat => '刚聊完，先让它待一会儿',
  };
}

class NudgeDecision {
  final bool allowed;
  final NudgeBlock reason;
  const NudgeDecision(this.allowed, this.reason);
}

/// 现在这个时刻能不能推。纯函数：所有输入都从参数进来，方便测也方便复算。
///
/// [isFollowUp] = 这条是便签到点了。**便签的时间是它自己在对话里定的**，
/// 所以两条规矩要松开：
///
/// - **不管「刚聊完」**。「我去做饭了」四十分钟后问「做好了吗」，接的就是刚才
///   那场对话——拿一个三小时的静默去否决它，等于把这个功能整个废掉。实测过：
///   常聊天的人根本等不到三小时安静，便签全都过期作废。
/// - **间隔用更短的那个**。两张便签可能只差二十分钟到点，那是两件事，
///   都值得问。
///
/// 其余三条（开关、静默时段、保险丝）对谁都一样：那三条护的是她，
/// 不是频率。
NudgeDecision decideNudge({
  required DateTime now,
  required NudgePrefs prefs,
  bool isFollowUp = false,
  DateTime? lastChatAt,
  DateTime? lastNudgeAt,
}) {
  if (!prefs.enabled) return const NudgeDecision(false, NudgeBlock.disabled);

  if (inQuietHours(now.hour, prefs)) {
    return const NudgeDecision(false, NudgeBlock.quietHours);
  }

  final gap =
      isFollowUp ? prefs.minGapAfterFollowUp : prefs.minGapBetweenNudges;
  if (lastNudgeAt != null && now.difference(lastNudgeAt) < gap) {
    return const NudgeDecision(false, NudgeBlock.tooSoonAfterNudge);
  }

  if (!isFollowUp &&
      lastChatAt != null &&
      now.difference(lastChatAt) < prefs.minSilenceAfterChat) {
    return const NudgeDecision(false, NudgeBlock.tooSoonAfterChat);
  }

  return const NudgeDecision(true, NudgeBlock.none);
}

/// 这条话和最近推过的那几条是不是一个意思。
///
/// 主动消息的通病是**重复**——它会反复说同一类话。单条读着没问题，
/// 连着三天收到同一句就假了：同一天被过了第二遍。
///
/// 用二元组的 Jaccard，不用编辑距离：中文里换个词、调个语序，编辑距离差很多，
/// 但共享的字对几乎一样——而「像不像同一句话」正是后者在量的东西。
bool looksRepeated(String text, List<String> recent, {double threshold = 0.6}) {
  final a = _bigrams(text);
  if (a.isEmpty) return false;
  for (final r in recent) {
    final b = _bigrams(r);
    if (b.isEmpty) continue;
    final inter = a.intersection(b).length;
    final union = a.union(b).length;
    if (union > 0 && inter / union >= threshold) return true;
  }
  return false;
}

Set<String> _bigrams(String s) {
  // 标点和空白不带信息，去掉之后短句之间才比得出差别。
  final clean = s.replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  if (clean.length < 2) return {clean};
  return {for (var i = 0; i < clean.length - 1; i++) clean.substring(i, i + 2)};
}

/// 静默时段判断，单独抽出来因为**跨零点那半最容易写错**。
///
/// 23→8 的意思是「23、0、1…7 都算静默，8 点开始不算」。写成
/// `h >= start && h < end` 在跨零点时永远为假，一条都拦不住。
bool inQuietHours(int hour, NudgePrefs prefs) {
  final start = prefs.quietStartHour;
  final end = prefs.quietEndHour;
  if (start == end) return false; // 没有静默时段
  if (start < end) return hour >= start && hour < end; // 同一天内
  return hour >= start || hour < end; // 跨零点
}
