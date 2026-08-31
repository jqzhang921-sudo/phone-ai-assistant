import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings.dart';
import '../models/chat_message.dart';
import 'ai_client.dart';
import 'nudge_gate.dart';
import 'storage_service.dart';

/// 主动推送：它自己决定什么时候说一句话，推到通知栏。
///
/// ## 分三步，顺序不能换
///
/// 1. [decideNudge] 判断**现在能不能说话**（纯函数，不联网）
/// 2. [compose] 问模型**有没有值得说的**——可以回「没有」
/// 3. [_show] 发通知
///
/// 门槛在最前面：过不了就根本不调模型，省钱，也省得模型每次都想说话。
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

  /// [force] 给设置页那个「现在试一次」用：跳过门槛，直接问模型。
  /// 门槛是给自动触发用的，手动点的时候拦下来只会让人以为功能坏了。
  static Future<NudgeRunResult> run({
    required AiClient aiClient,
    bool force = false,
  }) async {
    final now = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    final prefs = await loadPrefs();

    if (!force) {
      final decision = decideNudge(
        now: now,
        prefs: prefs,
        sentToday: await _sentToday(sp, now),
        lastChatAt: await lastChatAt(),
        lastNudgeAt: await _lastNudgeAt(sp),
      );
      if (!decision.allowed) {
        return NudgeRunResult.blocked(decision.reason);
      }
    }

    final String? text;
    try {
      text = await compose(aiClient: aiClient);
    } catch (e) {
      return NudgeRunResult.failed('生成失败：$e');
    }
    if (text == null || text.isEmpty) return NudgeRunResult.nothingToSay();

    if (!await ensurePermission()) {
      return NudgeRunResult.failed('没有通知权限');
    }
    await _show(text);
    await _bumpCount(sp, now);
    return NudgeRunResult.sent(text);
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

  /// 问模型有没有值得说的。返回 null = 没有，这次不推。
  static Future<String?> compose({required AiClient aiClient}) async {
    final messages = [
      ChatMessage(
        id: 'nudge_gen',
        role: MessageRole.user,
        content: await _composePrompt(),
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

  static Future<String> _composePrompt() async {
    final last = await lastChatAt();
    final now = DateTime.now();
    final gap =
        last == null
            ? '你们还没聊过。'
            : '距离你们上次说话过去了 ${_humanGap(now.difference(last))}。';

    // 人称约定和 musing_generator / history_compactor 一致：
    // 「你」是模型自己，「TA」是用户。这段 prompt 通篇管模型叫「你」。
    return '''
现在是 ${now.hour} 点。$gap TA 没有在跟你说话。

如果你**确实想起了一件具体的、值得现在告诉 TA 的事**，用一句话说出来，
40 字以内，就像随手发条微信。可以是你写完的一封信、翻到的一句旧话、
你记得的 TA 在忙的事到了该问一句的时候。

如果没有这样一件事，**只回两个字：不说**。这是正常的，多数时候就该这样。

三条硬规矩：

- **带来一件东西，不要索取一件东西。** 「好久没见你了」「你还在吗」
  「最近还好吗」这类一律不行——那是在讨要回应，不是在给什么。
- 不要提「多久没聊」这件事本身，一个字都不要提。
- 不要问问题。这是一条通知，TA 可能不会回。
''';
  }

  static String _humanGap(Duration d) {
    if (d.inHours < 1) return '不到一小时';
    if (d.inHours < 24) return '${d.inHours} 小时';
    return '${d.inDays} 天';
  }
}

/// 一次推送尝试的结果。**每种都要能说清楚为什么**——
/// 设置页那个「现在试一次」要把它原样显示出来。
class NudgeRunResult {
  final bool sent;
  final String message;
  final String? text;

  const NudgeRunResult._(this.sent, this.message, [this.text]);

  factory NudgeRunResult.sent(String text) =>
      NudgeRunResult._(true, '已推送', text);
  factory NudgeRunResult.blocked(NudgeBlock reason) =>
      NudgeRunResult._(false, reason.label);
  factory NudgeRunResult.nothingToSay() =>
      const NudgeRunResult._(false, '它这会儿没什么想说的');
  factory NudgeRunResult.failed(String why) => NudgeRunResult._(false, why);
}
