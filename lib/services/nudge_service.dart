import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings.dart';
import '../models/chat_message.dart';
import 'ai_client.dart';
import 'nudge_gate.dart';
import 'storage_service.dart';

/// 主动推送：他想开口的时候，给他一个出口。
///
/// ## 不是排班表，是出口
///
/// 第一版做成了「一天最多 N 条」——那是**配额**，会倒过来变成产出指标：
/// 今天还剩两条没用，就凑两条出来。和「每天必须收藏一条」是同一个毛病。
///
/// 现在的形状是：**冲动由发生过的事产生**，系统只决定哪条够格打扰她。
///
/// 1. [decideNudge] —— 现在能不能说话（纯函数，不联网）
/// 2. [collectCandidates] —— **有没有事情发生**。没有就到此为止，
///    连模型都不问：他确实没什么可说，这是正常状态，不是失败
/// 3. [compose] —— 有候选也不等于该说。让他自己决定说哪条、怎么说，
///    或者回「不说」
/// 4. 去重（[looksRepeated]）→ 发通知
///
/// 顺序的意义在于**越靠前越便宜**：门槛和候选都不花钱，模型只在真有事的时候
/// 才被叫醒。原来那版每次都问模型「你想说点什么吗」，那既费钱，又是在
/// 逼它凑话。
///
/// ## 这个形状是从哪来的
///
/// 同类的开源伴侣项目里，成熟一点的那套是「候选 + 编辑关」：各个子系统随时
/// 产出可以往外说的候选，再过一道编辑，不够格的降级进草稿池、留着不发。
/// [collectCandidates] + [compose] 就是那两层的小号版本。
///
/// 另有一种把「情绪往外走」分三层的说法：语调倾向 → 数值挣到一次行为 →
/// 攒够了主动发起一件事。**第三层公开的实现里基本都还没做**，
/// 所以这块没有现成答案可抄，下面是自己的判断。
///
/// ## ⚠️ 一条不写进代码就会被慢慢磨掉的规矩
///
/// **推送要带来一件东西，不能索取一件东西。**
///
/// 「刚写完一封信」「翻到你上个月说的那句话」可以；
/// 「好久没见你了」「你还在吗」不行——那是拿愧疚换打开率，是这类 App 最后都
/// 变得让人烦的原因。这条同时写在 [_composePrompt] 里和 [nudge_gate] 的注释里，
/// 两边都别删。
///
/// ## 目前还没接后台
///
/// 这一版只有「现在试一次」和「打开 App 时结算」两个入口。真后台唤醒
/// （workmanager）等这层跑顺了再接——ColorOS 上它本来就不保证准时，
/// 所以内容这层必须先能独立成立。
class NudgeService {
  static const _kPrefs = 'nudge_prefs';
  static const _kLastAt = 'nudge_last_at';
  static const _kCountDay = 'nudge_count_day';
  static const _kCount = 'nudge_count';
  static const _kRecent = 'nudge_recent';

  /// 拿多少条历史去比重复。太少挡不住轮流复读，太多会把正常的相似话题也误杀。
  static const _recentKeep = 6;

  static const _channelId = 'nudge';
  static const _channelName = '它主动说的话';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  // ---------------- 初始化和权限 ----------------

  static Future<void> init() async {
    if (_inited) return;
    await _plugin.initialize(
      const InitializationSettings(
        // 用应用图标。单色小图标更规范，但那要额外做一份 drawable，
        // 骨架阶段先不铺这个摊子。
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _inited = true;
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

  /// Android 13 起通知是运行时权限，清单里声明了也得问一次。
  /// 返回 null 当作「拿不准」，按有权限处理——13 以下本来就不会返回 true。
  static Future<bool> ensurePermission() async {
    await init();
    final granted = await _android?.requestNotificationsPermission();
    return granted ?? true;
  }

  // ---------------- 状态 ----------------

  /// 读不出来就用默认值。这是个附加功能，坏掉的偏好不该让它整个失灵。
  static Future<NudgePrefs> loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kPrefs);
    if (raw == null || raw.isEmpty) return const NudgePrefs();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const NudgePrefs();
      return NudgePrefs.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const NudgePrefs();
    }
  }

  static Future<void> savePrefs(NudgePrefs prefs) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefs, jsonEncode(prefs.toJson()));
  }

  /// 今天已经推了几条。跨天自动归零——存了「哪一天」才能判断，
  /// 只存计数的话隔夜就永远是满的。
  static Future<int> _sentToday(SharedPreferences sp, DateTime now) async {
    final day = sp.getString(_kCountDay);
    final today = '${now.year}-${now.month}-${now.day}';
    if (day != today) return 0;
    return sp.getInt(_kCount) ?? 0;
  }

  static Future<void> _bumpCount(SharedPreferences sp, DateTime now) async {
    final today = '${now.year}-${now.month}-${now.day}';
    final prev = sp.getString(_kCountDay) == today ? (sp.getInt(_kCount) ?? 0) : 0;
    await sp.setString(_kCountDay, today);
    await sp.setInt(_kCount, prev + 1);
    await sp.setInt(_kLastAt, now.millisecondsSinceEpoch);
  }

  static Future<DateTime?> _lastNudgeAt(SharedPreferences sp) async {
    final ms = sp.getInt(_kLastAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<List<String>> _recent(SharedPreferences sp) async =>
      sp.getStringList(_kRecent) ?? const [];

  static Future<void> _remember(SharedPreferences sp, String text) async {
    final list = [...await _recent(sp), text];
    await sp.setStringList(
      _kRecent,
      list.length <= _recentKeep
          ? list
          : list.sublist(list.length - _recentKeep),
    );
  }

  /// 最后一条消息的时间——门槛用它判断「是不是刚聊完」。
  static Future<DateTime?> lastChatAt() async {
    final convs = await StorageService.listConversations();
    DateTime? latest;
    for (final c in convs) {
      for (final m in c.messages) {
        if (latest == null || m.timestamp.isAfter(latest)) latest = m.timestamp;
      }
    }
    return latest;
  }

  // ---------------- 主流程 ----------------

  /// 他手上有没有一件真发生过的事。
  ///
  /// **这一层决定频率**，而不是某个配额。没有事情发生就没有冲动——
  /// 这时候连模型都不问：问了它只会凑一句出来，而凑出来的正是最假的那种推送。
  ///
  /// 现在的来源都是他自己产出的东西。用户收藏的「一隅」不算——那是她挑的，
  /// 不是他想说的。
  static Future<List<NudgeCandidate>> collectCandidates({
    DateTime? since,
  }) async {
    final out = <NudgeCandidate>[];
    final floor =
        since ?? DateTime.now().subtract(const Duration(days: 1));

    try {
      for (final l in await StorageService.listLetters()) {
        // 没读的信是最实在的一条：东西已经写好了，就在那儿等着。
        if (l.isFromAi && !l.read) {
          out.add(NudgeCandidate('信', '你给 TA 写的一封信还没被读，写于 ${_when(l.createdAt)}'));
        }
      }
    } catch (_) {}

    try {
      for (final d in await StorageService.listDiaryEntries()) {
        if (d.createdAt.isAfter(floor)) {
          out.add(NudgeCandidate('日记', '你刚记了一篇日记：${d.summary}'));
        }
      }
    } catch (_) {}

    return out;
  }

  /// [force] 给设置页那个「现在试一次」用：跳过门槛，但**不跳过候选**——
  /// 手动点也不该凭空造一条出来，否则试出来的东西和真实行为对不上。
  static Future<NudgeRunResult> run({
    required AiClient aiClient,
    bool force = false,
  }) async {
    final now = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    final prefs = await loadPrefs();
    final lastNudge = await _lastNudgeAt(sp);

    if (!force) {
      final decision = decideNudge(
        now: now,
        prefs: prefs,
        sentToday: await _sentToday(sp, now),
        lastChatAt: await lastChatAt(),
        lastNudgeAt: lastNudge,
      );
      if (!decision.allowed) return NudgeRunResult.blocked(decision.reason);
    }

    final candidates = await collectCandidates(since: lastNudge);
    if (candidates.isEmpty) return NudgeRunResult.nothingHappened();

    final String? text;
    try {
      text = await compose(aiClient: aiClient, candidates: candidates);
    } catch (e) {
      return NudgeRunResult.failed('生成失败：$e');
    }
    if (text == null || text.isEmpty) return NudgeRunResult.nothingToSay();

    if (looksRepeated(text, await _recent(sp))) {
      return NudgeRunResult.repeated(text);
    }

    if (!await ensurePermission()) {
      return NudgeRunResult.failed('没有通知权限');
    }
    await _show(text);
    await _bumpCount(sp, now);
    await _remember(sp, text);
    return NudgeRunResult.sent(text);
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return '刚刚';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  static Future<void> _show(String text) async {
    await init();
    var name = '';
    try {
      name = (await AppSettings.load()).aiName.trim();
    } catch (_) {}
    await _plugin.show(
      _channelId.hashCode,
      name.isEmpty ? '它说' : name,
      text,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: '它自己想说话的时候发一条',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // 一句话经常比通知栏一行长，展开能看全。
          styleInformation: BigTextStyleInformation(''),
        ),
      ),
    );
  }

  // ---------------- 内容 ----------------

  /// 编辑关：手上有这几件事，他要不要说、说哪件、怎么说。
  /// 返回 null = 他决定不说，这次不推。
  static Future<String?> compose({
    required AiClient aiClient,
    required List<NudgeCandidate> candidates,
  }) async {
    final messages = [
      ChatMessage(
        id: 'nudge_gen',
        role: MessageRole.user,
        content: await _composePrompt(candidates),
      ),
    ];

    var out = '';
    await for (final event in aiClient.chat(
      messages,
      systemPrompt:
          '你和用户长期相处。此刻 TA 没有在跟你说话，是你自己想起了什么。'
          '不要给这段关系起名字。',
    )) {
      if (event.type == AiEventType.token) {
        out += event.text ?? '';
      } else if (event.type == AiEventType.done) {
        out = event.text ?? out;
      } else if (event.type == AiEventType.error) {
        throw Exception(event.error ?? '生成失败');
      }
    }

    return _clean(out);
  }

  /// 把模型的回复收拾成一条能直接进通知栏的话，或者 null。
  ///
  /// 「没什么可说」这条路必须留得住：不留的话它每次都会硬凑一句，
  /// 凑出来的那种正是最招人烦的推送。
  static String? _clean(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // 模型说「不说」时可能带标点、带解释，只认开头。
    final head = s.replaceAll(RegExp(r'^[「"\s]+'), '');
    if (head.startsWith('不说')) return null;

    // 偶尔会自己加引号或者「」，剥掉。
    s = s.replaceAll(RegExp(r'^[「"]+|[」"]+$'), '').trim();
    return s.isEmpty ? null : s;
  }

  /// ⚠️ **不要在这段里贴反面例句的原文。**
  ///
  /// 写「不要说『好久没见你了』」会把那句话变成 few-shot 范例，越禁越像。
  /// 这不是推测——是别人在一个跑了三个月、每天几百轮的伴侣应用上量出来的：
  /// **要禁的行为一律抽象成正面的顺序和判据**。
  /// 第一版就是这么写坏的，把三句最怕它写出来的话原样贴了进去。
  ///
  /// 所以下面三条判据都是正面的、而且可以自己过一遍——
  /// 尤其最后一条，它把那条红线（带来一件东西，不索取）翻译成了一个可检查的
  /// 问题，而不用点名任何一句禁语。
  static Future<String> _composePrompt(List<NudgeCandidate> candidates) async {
    final now = DateTime.now();
    final list = candidates
        .map((c) => '- 【${c.kind}】${c.what}')
        .join('\n');

    // 人称约定和 musing_generator / history_compactor 一致：
    // 「你」是模型自己，「TA」是用户。
    return '''
现在是 ${now.hour} 点，TA 没有在跟你说话。

你这边刚刚真发生了这些事：

$list

挑其中**一件**，用一句话告诉 TA。40 字以内，像随手发一条微信。
说那件事本身：它是什么、你为什么这会儿想起它。

如果这几件都不值得现在打扰 TA，**只回两个字：不说**。
多数时候就该这样，这不是失败。

写完之后自己过一遍这三条，有一条不过就重写：

1. 这句话里有一件**具体的、已经存在的东西**吗（一封信、一篇日记、
   一个你记着的细节）？空着手的问候不算。
2. 主语是你自己这边的事吗？说的是你做了什么、想起了什么。
3. TA 读完之后不回，会不会觉得欠了你什么？会的话就重写——
   这条只是送到，不是来讨回应的。

不要问问题。这是一条通知，TA 可能只是看一眼就放下。
''';
  }
}

/// 一件真发生过的事，够格当作「他想开口」的由头。
///
/// 注意它记的是**事**不是话**——**说什么由 [NudgeService.compose] 决定。
/// 候选和话分开，是因为同一件事在不同时候值得说的方式不一样，
/// 而且候选这层不花钱，可以随便攒。
class NudgeCandidate {
  /// 归类，进 prompt 时当标签用（「信」「日记」）。
  final String kind;

  /// 一句话说清发生了什么，直接喂给模型。
  final String what;

  const NudgeCandidate(this.kind, this.what);
}

/// 一次尝试的结果。**每种都要能说清楚为什么**——设置页那个「现在试一次」
/// 要把它原样显示出来，点了没反应而不说原因，只会让人以为功能坏了。
///
/// 其中两种**不是失败**，文案要写得让人看得出来：
/// [nothingHappened]（没发生什么事）和 [nothingToSay]（他决定不说）。
class NudgeRunResult {
  final bool sent;
  final String message;
  final String? text;

  const NudgeRunResult._(this.sent, this.message, [this.text]);

  factory NudgeRunResult.sent(String text) =>
      NudgeRunResult._(true, '推出去了', text);
  factory NudgeRunResult.blocked(NudgeBlock reason) =>
      NudgeRunResult._(false, reason.label);
  factory NudgeRunResult.nothingHappened() => const NudgeRunResult._(
    false,
    '这会儿他手上没有事——没写信、没记日记。没有由头就不说话，这是对的',
  );
  factory NudgeRunResult.nothingToSay() =>
      const NudgeRunResult._(false, '有由头，但他自己觉得这会儿不值得打扰你');
  factory NudgeRunResult.repeated(String text) =>
      NudgeRunResult._(false, '和最近说过的太像了，压下了：$text', text);
  factory NudgeRunResult.failed(String why) => NudgeRunResult._(false, why);
}
