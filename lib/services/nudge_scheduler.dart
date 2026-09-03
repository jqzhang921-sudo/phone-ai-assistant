import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'app_providers.dart';
import 'letter_schedule.dart';
import 'nudge_service.dart';

/// 后台唤醒。让「主动说话」在 App 关着的时候也有机会发生。
///
/// ## 为什么轮询 15 分钟，而不是「到点了就推」
///
/// Android 的周期任务**最短就是 15 分钟**，而且系统只保证「大约」——它会
/// 攒着一批任务凑在一起跑，省电。所以这不是闹钟，是一次「看看有没有事」的
/// 巡查：绝大多数次会在 [NudgeService.run] 的前两步就返回（门槛没过，或者
/// 根本没有候选），**不联网、不调模型**，代价约等于读几个键。
///
/// 真正决定推不推的还是那两层，跟这里的频率无关。把频率调快只会更耗电，
/// 不会让它更想说话。
///
/// ## ⚠️ 国产 ROM 会杀后台，这条链本来就不保证准时
///
/// ColorOS / MIUI 那套省电策略会把周期任务掐掉或者大幅推迟，用户得手动给
/// App 开「自启动」和「后台运行」。所以：
///
/// - **内容那层必须能独立成立**——不能依赖「一定会在某个点被唤醒」
/// - 唤醒失败的后果只是「这条晚点再说」，不能是数据不一致
/// - 开着 App 的时候也走一遍（见 [runOnStartup]），后台被杀了至少还有这条路
class NudgeScheduler {
  static const _unique = 'nudge_periodic';
  static const _name = 'nudge';

  /// 在 `main()` 里调一次。只是把回调入口注册给原生侧，不会开始跑。
  static Future<void> init() async {
    await Workmanager().initialize(nudgeCallbackDispatcher);
  }

  /// 开关打开时调。[ExistingWorkPolicy.replace] 保证重复调用不会叠出多个任务。
  static Future<void> enable() async {
    await Workmanager().registerPeriodicTask(
      _unique,
      _name,
      frequency: const Duration(minutes: 15),
      // 立刻跑一次没意义：刚开开关时她人就在设置页，这会儿推一条最突兀。
      initialDelay: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      // 没网的时候连模型都调不了，让系统替我们省掉这次唤醒。
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.linear,
    );
  }

  static Future<void> disable() async {
    await Workmanager().cancelByUniqueName(_unique);
  }

  /// 进程启动时走一遍。
  ///
  /// 后台被 ROM 杀掉时这是还活着的路：她打开 App，攒下的那件事就有机会
  /// 说出口。门槛照走，所以不会因为多了这个入口就变吵。
  ///
  /// ⚠️ 这条**只在冷启动时跑**——它挂在根 widget 的 initState 上，那是
  /// 进程启动才走一次。Android 不会因为切走就杀进程，所以她连着用一整天的
  /// 话，这条兜底一次都不会再跑。切回前台那条见 [runOnResume]。
  static Future<void> runOnStartup() =>
      _runLocal(settle: const Duration(seconds: 3));

  /// 切回前台时走一遍。
  ///
  /// 补的是这个洞：进程活了一整天，期间**唯一的检查点只有后台周期任务**，
  /// 而那个在国产 ROM 上被攒到二三十分钟一次、还会整轮跳过。
  ///
  /// 延时比冷启动短得多：这会儿没有首屏要画，只需要躲开切回来那一下的动画。
  static Future<void> runOnResume() =>
      _runLocal(settle: const Duration(milliseconds: 600));

  /// 上一次在前台跑是什么时候。**进程内的，重启就忘**——冷启动本来就会跑一次，
  /// 忘掉正好对上。
  static DateTime? _lastLocalRun;

  /// 两次前台检查之间至少隔多久。
  ///
  /// 不是怕它话多（门槛管那个），是怕**掉帧**：每次都要读信、日记、对话列表，
  /// 全在主 isolate 上。而她复制个验证码切出去再回来就是一次 resumed，
  /// 一天几十次——没有这道闸，那就是几十次文件遍历。
  static const _localGap = Duration(minutes: 30);

  /// 纯的，好测：[last] 是上次跑的时间，null = 没跑过。
  static bool shouldRunLocally(DateTime now, DateTime? last) =>
      last == null || now.difference(last) >= _localGap;

  /// **不弹通知**（`notify: false`）：人已经在 App 里了，为一条马上就能看到的
  /// 消息再弹一条通知是噪音。话照样落进对话，她翻到就看见。
  static Future<void> _runLocal({required Duration settle}) async {
    final now = DateTime.now();
    if (!shouldRunLocally(now, _lastLocalRun)) return;
    _lastLocalRun = now;
    try {
      // ⚠️ 让界面先画完。
      //
      // 这条路要读文件、可能还要调模型，全在主 isolate 上。跟首屏抢会直接掉帧，
      // 而它一点都不急——攒下的事晚几秒说没有任何区别。
      await Future.delayed(settle);

      final prefs = await NudgeService.loadPrefs();
      if (!prefs.enabled) return;
      final client = await buildStoredAiClient();
      if (client == null) return;
      await NudgeService.run(aiClient: client, notify: false);
    } catch (e) {
      debugPrint('[nudge] 前台这次没跑成：$e');
    }
  }
}

/// 后台 isolate 的入口。
///
/// ⚠️ 三条都不能少，少一条就是「装上之后永远不响，也没有报错」：
///
/// 1. **顶层函数**——要能被 `PluginUtilities.getCallbackHandle` 拿到句柄，
///    类的静态方法不行
/// 2. **`@pragma('vm:entry-point')`**——release 构建下没有它会被 tree-shake
///    掉，debug 下却是好的，所以这个坑只在装了正式包之后才现形
/// 3. **一律 `return true`**——返回 false 会让 WorkManager 认为任务失败并按
///    退避策略重试。而「他没什么想说的」是正常结果，不是失败，重试只会浪费
///    唤醒次数
@pragma('vm:entry-point')
void nudgeCallbackDispatcher() {
  // executeTask 内部已经做了 WidgetsFlutterBinding 和 DartPluginRegistrant
  // 的初始化，所以这里能直接用 SharedPreferences、通知插件这些。
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await NudgeService.loadPrefs();
      if (!prefs.enabled) {
        await NudgeService.noteRun('醒了，但主动说话是关着的');
        return true;
      }

      final client = await buildStoredAiClient();
      if (client == null) {
        // 最可疑的一条：密钥存在 keystore（flutter_secure_storage）里，
        // 后台 isolate 读不读得到不一定。读不到就等于没配模型。
        await NudgeService.noteRun('醒了，但读不到模型配置（后台拿不到密钥？）');
        return true;
      }

      // 排在推送前面：到点的信在这一轮就写出来，紧接着它自己就成了候选。
      // 「我刚写完一封信」这句话第一次能在真的刚写完的时候说出口——
      // 前提就是写这个动作发生在她不看手机的时候。
      await LetterSchedule.writeIfDue(aiClient: client);

      await NudgeService.run(aiClient: client);
    } catch (e) {
      // 后台里抛出去没人接得住，而且会被系统记成任务失败触发重试。
      // debugPrint 在这里是白写的：国产 ROM 封了非调试包的 logcat，
      // 所以异常也要落到那行记录上，否则又是一次「什么都看不见」。
      debugPrint('[nudge] 后台这次没跑成：$e');
      await NudgeService.noteRun('醒了，但出错了：$e');
    }
    return true;
  });
}
