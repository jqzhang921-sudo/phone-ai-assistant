import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/settings.dart';
import '../models/chat_message.dart';
import 'ai_client.dart';
import '../config/persona.dart';
import 'memory_context.dart';
import 'self_notes.dart';
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
/// ## 三个入口
///
/// 后台周期任务（见 `nudge_scheduler.dart`）、App 启动时的兜底、
/// 设置页那个「现在试一次」。前两个都可能被系统掐掉或者根本没机会跑，
/// 所以**内容这层必须能独立成立**——不能依赖「一定会在某个点被唤醒」。
class NudgeService {
  static const _kPrefs = 'nudge_prefs';
  static const _kLastAt = 'nudge_last_at';
  // ⚠️ 键名从 nudge_count 换成了 nudge_notified_*，因为**含义变了**：
  // 现在只数「真弹了通知的」。旧键留在磁盘上不管它——顺带把线上那个已经被
  // 烧穿的计数一起丢掉，那是按旧含义攒出来的，按新含义不该算数。
  static const _kCountDay = 'nudge_notified_day';
  static const _kCount = 'nudge_notified_count';
  static const _kRecent = 'nudge_recent';
  static const _kLastRun = 'nudge_last_run';
  static const _kMentioned = 'nudge_mentioned';

  /// 记住多少条「已经提过的事」。留得住几十件就够——超出这个数的信和日记，
  /// 早就不是「刚发生」的了，本来也不该再当由头。
  static const _mentionedKeep = 60;

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

  /// [notified] = 这次真弹了通知。
  ///
  /// ⚠️ **静默的那次不能算进保险丝。** 保险丝防的是「一天弹太多通知」，而
  /// `runOnStartup` 走的是 `notify: false`——只把话写进对话，人本来就在 App 里。
  ///
  /// 真机上就是这么烧穿的：一天给她装了九次包，每次装完 App 重启就跑一次
  /// `runOnStartup`，四条额度全耗在静默写入上，而她一条通知都没看到，
  /// 后台那边只报「保险丝断了」。
  ///
  /// 「上次说话是什么时候」不受这条影响：静默说过也是说过，间隔照算，
  /// 否则它会接二连三地说。
  static Future<void> _bumpCount(
    SharedPreferences sp,
    DateTime now, {
    required bool notified,
  }) async {
    await sp.setInt(_kLastAt, now.millisecondsSinceEpoch);
    if (!notified) return;
    final today = '${now.year}-${now.month}-${now.day}';
    final prev =
        sp.getString(_kCountDay) == today ? (sp.getInt(_kCount) ?? 0) : 0;
    await sp.setString(_kCountDay, today);
    await sp.setInt(_kCount, prev + 1);
  }

  static Future<DateTime?> _lastNudgeAt(SharedPreferences sp) async {
    final ms = sp.getInt(_kLastAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 上一次唤醒干了什么，给设置页显示。
  ///
  /// ## 为什么非要有这个
  ///
  /// 后台唤醒跑在独立 isolate 里，release 包又拿不到 logcat（国产 ROM 对非调试
  /// 包封了日志）。于是「它没说话」这件事完全是个黑盒：是没醒？醒了但没到点？
  /// 到点了但它自己决定不说？三种情况的下一步动作完全不同。
  ///
  /// 更糟的是**聊天里那个模型看不到后台**，你问它「刚才收到唤醒没」，
  /// 它会顺着话编一个原因出来——听着有理，实际没有任何依据。
  ///
  /// 所以把每次的结果落到磁盘上。一行字，但它是这个功能唯一的证据。
  /// 给 `nudge_scheduler` 记它自己那两条早退路径用。
  ///
  /// ⚠️ 没有这个的话诊断有个洞：唤醒后要是**拿不到模型配置**（密钥在 keystore
  /// 里，后台 isolate 能不能读到不一定），`run()` 压根没被调到，于是什么都不会
  /// 记——而那恰好是最可疑的一条路。「没有记录」和「没醒过」看起来一模一样。
  static Future<void> noteRun(String outcome) => _recordRun(outcome);

  static Future<void> _recordRun(String outcome) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kLastRun,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'outcome': outcome,
        }),
      );
    } catch (_) {}
  }

  /// (什么时候, 结果)。从来没跑过就返回 null。
  static Future<(DateTime, String)?> lastRun() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kLastRun);
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final at = DateTime.tryParse(m['at'] as String? ?? '');
      final outcome = m['outcome'] as String?;
      if (at == null || outcome == null) return null;
      return (at, outcome);
    } catch (_) {
      return null;
    }
  }

  static Future<List<String>> _recent(SharedPreferences sp) async =>
      sp.getStringList(_kRecent) ?? const [];

  static Future<Set<String>> _mentioned() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_kMentioned) ?? const <String>[]).toSet();
  }

  static Future<void> _markMentioned(String key) async {
    final sp = await SharedPreferences.getInstance();
    // ⚠️ `const []` 会让整个列表推成 List<dynamic>，得写 `const <String>[]`。
    // flutter analyze 放过了这个，flutter test 才报出来——编译前端比分析器严。
    final list = <String>[...(sp.getStringList(_kMentioned) ?? const []), key];
    await sp.setStringList(
      _kMentioned,
      list.length <= _mentionedKeep
          ? list
          : list.sublist(list.length - _mentionedKeep),
    );
  }

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
  ///
  /// ⚠️ 走文件的修改时间，**不解析 JSON**。原来是把每段对话全读出来再遍历
  /// 每条消息找最大时间戳，为了一个时间戳解析上兆的文本，而这件事在 App
  /// 启动时就要做一次——实测就是掉帧的来源。
  static Future<DateTime?> lastChatAt() =>
      StorageService.lastConversationWriteAt();

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
    final now = DateTime.now();
    final out = <NudgeCandidate>[];
    final floor = since ?? now.subtract(const Duration(days: 1));

    // 便签排在最前面：它是他自己定的时间、自己记着的事，分量比「我写了封信」
    // 重——那种只是他产出了东西，这种是他记着你说过的话。
    try {
      for (final n in await SelfNoteStore.due(now)) {
        out.add(
          NudgeCandidate(
            '没说完的事',
            '${_ago(n.createdAt)}你留给自己的：${n.about}',
            conversationId: n.conversationId,
            noteId: n.id,
          ),
        );
      }
    } catch (_) {}

    // 提过的就不再当由头了。**一件事只提一次**——她没动，不是因为没听见。
    final mentioned = await _mentioned();

    try {
      for (final l in await StorageService.listLetters()) {
        // 没读的信是最实在的一条：东西已经写好了，就在那儿等着。
        if (l.isFromAi && !l.read && !mentioned.contains('letter:${l.id}')) {
          out.add(
            NudgeCandidate(
              '信',
              '你给 TA 写的一封信还没被读，写于 ${_when(l.createdAt)}',
              mentionKey: 'letter:${l.id}',
            ),
          );
        }
      }
    } catch (_) {}

    try {
      for (final d in await StorageService.listDiaryEntries()) {
        if (d.createdAt.isAfter(floor) &&
            !mentioned.contains('diary:${d.id}')) {
          out.add(
            NudgeCandidate(
              '日记',
              '你刚记了一篇日记：${d.summary}',
              mentionKey: 'diary:${d.id}',
            ),
          );
        }
      }
    } catch (_) {}

    return out;
  }

  /// [force] 给设置页那个「现在试一次」用：跳过门槛，但**不跳过候选**——
  /// 手动点也不该凭空造一条出来，否则试出来的东西和真实行为对不上。
  /// [notify] = false 时只把话写进对话，不弹通知。
  /// App 正开着的时候用这个：为一条已经在屏幕上的消息再弹一条通知是噪音。
  ///
  /// 无论走哪条分支都会记一笔（见 [_recordRun]）——这是这个功能唯一的证据，
  /// 后台那条路既看不到日志，也问不出真话。
  static Future<NudgeRunResult> run({
    required AiClient aiClient,
    bool force = false,
    bool notify = true,
  }) async {
    final r = await _runInner(
      aiClient: aiClient,
      force: force,
      notify: notify,
    );
    await _recordRun(r.sent ? '说了：${r.text}' : r.message);
    return r;
  }

  static Future<NudgeRunResult> _runInner({
    required AiClient aiClient,
    bool force = false,
    bool notify = true,
  }) async {
    final now = DateTime.now();
    final sp = await SharedPreferences.getInstance();
    final prefs = await loadPrefs();
    final lastNudge = await _lastNudgeAt(sp);

    // ⚠️ 候选在门槛**前面**收，顺序不能反。
    //
    // 门槛里有两条对便签是松的（见 decideNudge 的 isFollowUp），而「是不是
    // 便签」只有收完候选才知道。原来先过门槛，于是常聊天的人永远等不到那三
    // 小时安静，便签全部过期作废——功能等于没做。
    //
    // 换顺序不亏：收候选全是本地读，和门槛一样便宜。真正贵的是模型那一步，
    // 它仍然排在两者之后。
    final candidates = await collectCandidates(since: lastNudge);
    if (candidates.isEmpty) return NudgeRunResult.nothingHappened();

    // **我们挑一件，他决定说不说、怎么说。**
    //
    // 让他自己从几件里挑，我们就不知道他用了哪条——便签不知道该清哪张，
    // 话也不知道该推回哪段对话。挑的规矩写在 [_pick] 里，很浅；
    // 真正的判断（这会儿值不值得打扰她）仍然在他那边。
    final picked = _pick(candidates);

    if (!force) {
      final decision = decideNudge(
        now: now,
        prefs: prefs,
        isFollowUp: picked.noteId != null,
        lastChatAt: await lastChatAt(),
        lastNudgeAt: lastNudge,
      );
      if (!decision.allowed) return NudgeRunResult.blocked(decision.reason);
    }

    final String? text;
    try {
      text = await compose(aiClient: aiClient, candidate: picked);
    } catch (e) {
      return NudgeRunResult.failed('生成失败：$e');
    }
    if (text == null || text.isEmpty) return NudgeRunResult.nothingToSay();

    if (looksRepeated(text, await _recent(sp))) {
      return NudgeRunResult.repeated(text);
    }

    if (notify && !await ensurePermission()) {
      return NudgeRunResult.failed('没有通知权限');
    }
    // 先落进对话，再弹通知。反过来的话，通知先到、她点开发现聊天里什么都没有。
    await _appendToChat(text, conversationId: picked.conversationId);
    if (notify) await _show(text);
    await _bumpCount(sp, now, notified: notify);
    await _remember(sp, text);
    // 兑现完就把便签清掉，否则下次醒来还会再问一遍同一件事。
    // 只在真发出去之后清——他说「不说」的时候留着，下次再判断。
    if (picked.noteId != null) await SelfNoteStore.remove(picked.noteId!);
    // 登记「这件事提过了」。只在真发出去之后登记——他说「不说」的时候不算提过。
    if (picked.mentionKey != null) await _markMentioned(picked.mentionKey!);
    return NudgeRunResult.sent(text);
  }

  /// 手上有几件事时挑哪一件。
  ///
  /// 规矩很浅，因为**深的判断该由他做**：这里只保证挑出来的那件不荒唐。
  ///
  /// 便签排在最前：那是他自己定了时间、自己记着的事，而且**有时效**——
  /// 「做好了吗」过了那个点就不值钱了。信和日记不急，晚一轮说没损失。
  static NudgeCandidate _pick(List<NudgeCandidate> candidates) {
    final notes = candidates.where((c) => c.noteId != null).toList();
    return notes.isNotEmpty ? notes.first : candidates.first;
  }

  /// 把它主动说的这句写进对话里。
  ///
  /// **通知只是提醒，话本身得留在聊天里。** 不写的话有两个后果，第二个更要命：
  ///
  /// 1. 她顺着通知点进来，聊天框里什么都没有
  /// 2. **它自己也不知道说过这句** —— 下一轮的历史里没有这条，于是它会重复、
  ///    会答非所问（她回「好啊」，它不知道在回什么）
  ///
  /// [conversationId] 指定推回哪段（便签自带来源）。空或者那段已经不在了，
  /// 就退回**最近动过的那段**：她要找也是去那儿找。一段都没有就跳过，
  /// 不为了发一条通知凭空建一段对话。
  static Future<void> _appendToChat(
    String text, {
    String conversationId = '',
  }) async {
    try {
      final convs = await StorageService.listConversations();
      if (convs.isEmpty) return;
      convs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final conv = convs.firstWhere(
        (c) => c.id == conversationId,
        orElse: () => convs.first,
      );
      conv.messages.add(
        ChatMessage(
          id: 'nudge_${DateTime.now().millisecondsSinceEpoch}',
          role: MessageRole.assistant,
          content: text,
          // 界面靠这个标记把它和「回你的话」分开显示。
          // 用 metadata 而不是新加字段：这只是一条 assistant 消息的来历，
          // 不是一种新的消息类型——发回服务端时它仍旧是普通的一句。
          metadata: const {'nudge': true},
        ),
      );
      // updatedAt 不在这儿动：saveConversation 会按最后一条消息的时间收口，
      // 两处各写各的迟早会打架。
      await StorageService.saveConversation(conv);
    } catch (_) {
      // 写不进去也别让通知发不出来——话到了总比什么都没有强。
    }
  }

  /// 最近动过那段对话的尾巴，给 [compose] 当上下文。
  ///
  /// 只取尾部几条：这一步是判断「这会儿开口自不自然」，不是回顾整段关系。
  /// 长期的那部分由记忆摘要负责。
  static Future<String> _recentTranscript({int take = 8}) async {
    try {
      final convs = await StorageService.listConversations();
      if (convs.isEmpty) return '';
      convs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final msgs =
          convs.first.messages
              .where(
                (m) =>
                    (m.role == MessageRole.user ||
                        m.role == MessageRole.assistant) &&
                    m.content.trim().isNotEmpty,
              )
              .toList();
      final tail = msgs.length <= take ? msgs : msgs.sublist(msgs.length - take);
      return tail
          .map(
            (m) =>
                '${m.role == MessageRole.user ? 'TA' : '你'}：'
                '${m.content.trim()}',
          )
          .join('\n');
    } catch (_) {
      return '';
    }
  }

  static String _when(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inHours < 1) return '刚刚';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 便签用的粒度要细到分钟：等四十分钟的事说成「刚刚」就没意义了。
  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
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

  /// 编辑关：手上这件事，他要不要说、怎么说。
  /// 返回 null = 他决定不说，这次不推。
  static Future<String?> compose({
    required AiClient aiClient,
    required NudgeCandidate candidate,
  }) async {
    final messages = [
      ChatMessage(
        id: 'nudge_gen',
        role: MessageRole.user,
        content: await _composePrompt(candidate),
      ),
    ];

    // ⚠️ 这里原来写死一段临时人设，于是**主动说话的时候它不是它**：
    // 名字没有、她设的性格没有，说出来的话跟聊天里那个不像同一个。
    // 而「热情还是克制」恰恰决定了这一句该不该说、怎么说——
    // 没有性格，这一层就只剩下模板。
    //
    // 现在和聊天走同一份身份（见 buildIdentityPrompt），只在后面补一句
    // 「此刻她没在跟你说话」交代处境。
    var identity = '';
    try {
      identity = await buildIdentityPrompt();
    } catch (_) {}

    var out = '';
    await for (final event in aiClient.chat(
      messages,
      systemPrompt: [
        if (identity.isNotEmpty) identity,
        '此刻 TA 没有在跟你说话，是你自己想起了什么。',
      ].join('\n\n'),
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
  static Future<String> _composePrompt(NudgeCandidate candidate) async {
    final now = DateTime.now();
    final list = '- 【${candidate.kind}】${candidate.what}';

    // 要它「根据上下文判断」，就得真给它上下文。只给一个候选和一个钟点，
    // 它能判断的只有「几点了」——那不叫判断，那叫查表。
    //
    // 两样：最近说过什么（决定这会儿开口自不自然、会不会撞上刚聊完的话题），
    // 和它长期记着她的那些（决定这件事对她算不算事）。
    final tail = await _recentTranscript();
    var digest = '';
    try {
      digest = await buildMemoryDigest();
    } catch (_) {}

    // 人称约定和 musing_generator / history_compactor 一致：
    // 「你」是模型自己，「TA」是用户。
    return '''
现在是 ${now.hour} 点，TA 没有在跟你说话。

你这边有一件事：

$list

${digest.isEmpty ? '' : '$digest\n'}${tail.isEmpty ? '你们最近没说过话。' : '你们最近说的话（「你」是你自己，「TA」是她）：\n$tail'}

要是这会儿值得说，就用一句话告诉 TA。40 字以内，像随手发一条微信。
说那件事本身：它是什么、你为什么这会儿想起它。

**时间本身就是信息。** 刚写完的信和放了三天没被打开的信，值得说的东西不一样，
语气也不一样——三天前那封，重点已经不是「我写了」，而是它还在那儿。
这个分寸你自己拿捏，不用问。

如果这会儿不值得为它打扰 TA，**只回两个字：不说**。
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
  /// 归类，进 prompt 时当标签用（「信」「日记」「没说完的事」）。
  final String kind;

  /// 一句话说清发生了什么，直接喂给模型。
  final String what;

  /// 这条该推回哪段对话。空 = 没有归属，退回「最近动过的那段」。
  ///
  /// 便签有归属：「做好了吗」接的是那段对话里的「我去做饭了」，
  /// 推到别处话就断了。信和日记没有归属，因为它们不是从某次对话里长出来的。
  final String conversationId;

  /// 兑现之后要清掉的便签 id。信和日记没有这个（它们不消耗）。
  final String? noteId;

  /// 「这件事已经提过了」的登记名，比如 `letter:<id>`。
  ///
  /// ⚠️ **没读的信是常驻候选**：不像便签说完就撕、也不像日记有时间下限，
  /// 只要她不读，它就一直在候选列里。原来「刚聊完」那道门槛是 3 小时，
  /// 几乎撞不上所以没暴露；降到 1 小时之后，同一封信可能每小时被念叨一次。
  ///
  /// 而这正是那条规矩说的：**变味的不是那句话，是说第二遍。**
  /// 去重（[looksRepeated]）只按字面挡，换个说法就滑过去了——按来源登记才挡得住。
  final String? mentionKey;

  const NudgeCandidate(
    this.kind,
    this.what, {
    this.conversationId = '',
    this.noteId,
    this.mentionKey,
  });
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
