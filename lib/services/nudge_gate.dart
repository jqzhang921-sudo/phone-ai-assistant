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

/// 用户能调的那几个数。默认值都偏保守——推少了只是没惊喜，推多了会被关掉。
class NudgePrefs {
  final bool enabled;

  /// 静默时段，闭开区间 [start, end)，按小时。默认 23:00–08:00，跨零点。
  final int quietStartHour;
  final int quietEndHour;

  /// 一天最多几条。
  final int maxPerDay;

  /// 两条推送之间至少隔多久。
  final Duration minGapBetweenNudges;

  /// 最后一次聊天之后至少静默多久才考虑推。
  /// 刚聊完就弹一条，读起来像它没听见你刚说的话。
  final Duration minSilenceAfterChat;

  const NudgePrefs({
    this.enabled = false,
    this.quietStartHour = 23,
    this.quietEndHour = 8,
    this.maxPerDay = 2,
    this.minGapBetweenNudges = const Duration(hours: 4),
    this.minSilenceAfterChat = const Duration(hours: 3),
  });

  NudgePrefs copyWith({
    bool? enabled,
    int? quietStartHour,
    int? quietEndHour,
    int? maxPerDay,
  }) => NudgePrefs(
    enabled: enabled ?? this.enabled,
    quietStartHour: quietStartHour ?? this.quietStartHour,
    quietEndHour: quietEndHour ?? this.quietEndHour,
    maxPerDay: maxPerDay ?? this.maxPerDay,
    minGapBetweenNudges: minGapBetweenNudges,
    minSilenceAfterChat: minSilenceAfterChat,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'quietStartHour': quietStartHour,
    'quietEndHour': quietEndHour,
    'maxPerDay': maxPerDay,
  };

  factory NudgePrefs.fromJson(Map<String, dynamic> json) => NudgePrefs(
    enabled: json['enabled'] as bool? ?? false,
    quietStartHour: json['quietStartHour'] as int? ?? 23,
    quietEndHour: json['quietEndHour'] as int? ?? 8,
    maxPerDay: json['maxPerDay'] as int? ?? 2,
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
  dailyCap,
  tooSoonAfterNudge,
  tooSoonAfterChat,
}

extension NudgeBlockLabel on NudgeBlock {
  String get label => switch (this) {
    NudgeBlock.none => '可以推',
    NudgeBlock.disabled => '主动推送没开',
    NudgeBlock.quietHours => '在静默时段里',
    NudgeBlock.dailyCap => '今天已经推够了',
    NudgeBlock.tooSoonAfterNudge => '离上一条推送太近',
    NudgeBlock.tooSoonAfterChat => '刚聊完，先让它待一会儿',
  };
}

class NudgeDecision {
  final bool allowed;
  final NudgeBlock reason;
  const NudgeDecision(this.allowed, this.reason);
}

/// 现在这个时刻能不能推。纯函数：所有输入都从参数进来，方便测也方便复算。
NudgeDecision decideNudge({
  required DateTime now,
  required NudgePrefs prefs,
  required int sentToday,
  DateTime? lastChatAt,
  DateTime? lastNudgeAt,
}) {
  if (!prefs.enabled) return const NudgeDecision(false, NudgeBlock.disabled);

  if (inQuietHours(now.hour, prefs)) {
    return const NudgeDecision(false, NudgeBlock.quietHours);
  }

  if (sentToday >= prefs.maxPerDay) {
    return const NudgeDecision(false, NudgeBlock.dailyCap);
  }

  if (lastNudgeAt != null &&
      now.difference(lastNudgeAt) < prefs.minGapBetweenNudges) {
    return const NudgeDecision(false, NudgeBlock.tooSoonAfterNudge);
  }

  if (lastChatAt != null &&
      now.difference(lastChatAt) < prefs.minSilenceAfterChat) {
    return const NudgeDecision(false, NudgeBlock.tooSoonAfterChat);
  }

  return const NudgeDecision(true, NudgeBlock.none);
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
