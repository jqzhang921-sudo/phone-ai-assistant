import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_glance/screen_glance.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_usage.dart';

/// 让它看一眼屏幕。
///
/// ## 和 [AppUsage] 的关系
///
/// 当初选「用了哪个 App、多久」是**替代截屏**的——截屏会把整块屏幕传出去。
/// 2026-09-15 Cleo 说想要真的能看一眼：后台醒来、好久没说话、它想知道她在
/// 干什么。所以这条路是**她点头之后**加的，不是那个判断被忘了。
///
/// 那个判断里的顾虑照样落地，全在原生那边的 `precheck` 和这里：
///
/// - **两道开关**：系统无障碍里开服务（权限），App 设置里「允许它看」（意愿）。
///   只开了前一个不算数——无障碍设置页里的开关她可能是顺手点的
/// - **锁屏、灭屏不看**：她不在手机前面，看到的是锁屏壁纸，还白花一次模型
/// - **在我们自己 App 里不看**：截到的只是聊天页
/// - **排除名单里的 App 不看**：复用 [AppUsage] 那份，一份名单管两件事
/// - **支付、密码页截不到**：系统拒绝（FLAG_SECURE），这是对的
/// - **看过一定留痕**：截到的图写进对话（见 `NudgeService`），她随时翻得到
class ScreenGlance {
  static const _channel = MethodChannel(screenGlanceChannel);
  static const _kAllowed = 'glance_allowed';
  static const _kLastAt = 'glance_last_at';

  /// 截图长边缩到多少。1280 够认出是哪个 App、大概在看什么；原尺寸
  /// 1080×2400 发出去是现在的两倍多 token，多出来的细节它用不上。
  static const maxSide = 1280;
  static const quality = 70;

  // ---------------- 她的意愿 ----------------

  /// 「允许它看」。默认关：这是她主动要的，不替她打开。
  static Future<bool> allowed() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kAllowed) ?? false;
  }

  static Future<void> setAllowed(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kAllowed, v);
  }

  /// 上次**真看了**是什么时候（截成功才算）。
  static Future<DateTime?> lastAt() async {
    final sp = await SharedPreferences.getInstance();
    final ms = sp.getInt(_kLastAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> markLooked(DateTime at) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kLastAt, at.millisecondsSinceEpoch);
  }

  // ---------------- 系统那边 ----------------

  static Future<GlanceStatus> status() async {
    try {
      final m = await _channel
          .invokeMapMethod<String, dynamic>('status')
          .timeout(const Duration(seconds: 3));
      return GlanceStatus(
        supported: m?['supported'] == true,
        enabled: m?['enabled'] == true,
        bound: m?['bound'] == true,
      );
    } catch (_) {
      // 不是安卓、测试里没插件、通道卡住：都当「这台机器上用不了」。
      return const GlanceStatus(supported: false, enabled: false, bound: false);
    }
  }

  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 现在能不能看。**不截图**。
  ///
  /// 放在问模型之前：锁着屏、她在排除的 App 里，就别白花一次模型调用。
  ///
  /// [allowInApp]：她开着悬浮窗聊天时传 true，见 [GlanceWindow.floating]。
  static Future<GlanceCheck> check({bool allowInApp = false}) async {
    if (!await allowed()) return const GlanceCheck.miss(GlanceMiss.notAllowed);
    final raw = await _invoke(
      'check',
      const Duration(seconds: 3),
      extra: {'allowInApp': allowInApp},
    );
    return GlanceCheck.fromMap(raw);
  }

  /// 截一张。成功时 [GlanceCheck.bytes] 是 WebP。
  ///
  /// 截之前原生那边会**再查一遍**锁屏和排除名单——从 [check] 到这里隔着
  /// 一次模型调用，几秒钟里她可能已经切到了别的 App。
  static Future<GlanceCheck> capture({bool allowInApp = false}) async {
    if (!await allowed()) return const GlanceCheck.miss(GlanceMiss.notAllowed);
    final raw = await _invoke(
      'capture',
      const Duration(seconds: 10),
      extra: {
        'maxSide': maxSide,
        'quality': quality,
        'allowInApp': allowInApp,
      },
    );
    return GlanceCheck.fromMap(raw);
  }

  static Future<Map<String, dynamic>?> _invoke(
    String method,
    Duration timeout, {
    Map<String, dynamic> extra = const {},
  }) async {
    try {
      final excluded = await AppUsage.excludedPackages();
      return await _channel
          .invokeMapMethod<String, dynamic>(method, {
            'excluded': excluded.toList(),
            ...extra,
          })
          // 在后台里平台通道要是卡住，没有任何东西会把它叫醒——整轮主动说话
          // 就挂在这儿。宁可当作没看成。
          .timeout(timeout);
    } on TimeoutException {
      return {'miss': 'failed', 'detail': '超时'};
    } on MissingPluginException {
      return {'miss': 'unsupported'};
    } catch (e) {
      return {'miss': 'failed', 'detail': '$e'};
    }
  }
}

class GlanceStatus {
  /// 安卓 11 以上才有无障碍截屏。
  final bool supported;

  /// 她在系统设置里开了没有。
  final bool enabled;

  /// 系统现在绑没绑上。开了但没绑上 = 进程刚被杀、系统还没拉起来，或者 ROM
  /// 把它关了没告诉设置页。
  final bool bound;

  const GlanceStatus({
    required this.supported,
    required this.enabled,
    required this.bound,
  });

  bool get ready => supported && bound;
}

/// 为什么没看成。每条都要说得清——设置页和「上次跑的结果」要原样显示。
enum GlanceMiss {
  notAllowed,
  unsupported,
  off,
  screenOff,
  locked,
  inApp,
  excluded,
  secure,
  tooFast,
  failed,
}

extension GlanceMissLabel on GlanceMiss {
  String get label => switch (this) {
    GlanceMiss.notAllowed => '没允许它看屏幕',
    GlanceMiss.unsupported => '这台手机的系统版本不支持（要安卓 11 以上）',
    GlanceMiss.off => '无障碍里的「让它看一眼屏幕」没开，或者被系统关掉了',
    GlanceMiss.screenOff => '屏幕是灭的',
    GlanceMiss.locked => '手机锁着',
    GlanceMiss.inApp => '你就在 App 里',
    GlanceMiss.excluded => '你在用排除名单里的 App',
    GlanceMiss.secure => '这一页系统不让截（支付、密码这类）',
    GlanceMiss.tooFast => '截得太快了，系统让等一下',
    GlanceMiss.failed => '截图失败了',
  };

  static GlanceMiss parse(String? raw) => switch (raw) {
    'unsupported' => GlanceMiss.unsupported,
    'off' => GlanceMiss.off,
    'screen_off' => GlanceMiss.screenOff,
    'locked' => GlanceMiss.locked,
    'in_app' => GlanceMiss.inApp,
    'excluded' => GlanceMiss.excluded,
    'secure' => GlanceMiss.secure,
    'too_fast' => GlanceMiss.tooFast,
    _ => GlanceMiss.failed,
  };
}

class GlanceCheck {
  /// null = 能看（[check]）或者截到了（[capture]）。
  final GlanceMiss? miss;

  /// 前台 App 的包名和名字。排除名单里的不回——名单的意思就是当它不存在。
  final String? package;
  final String? label;

  /// 截到的图，WebP。只有 [ScreenGlance.capture] 成功时有。
  final Uint8List? bytes;

  final String? detail;

  const GlanceCheck({
    this.miss,
    this.package,
    this.label,
    this.bytes,
    this.detail,
  });

  const GlanceCheck.miss(GlanceMiss this.miss)
    : package = null,
      label = null,
      bytes = null,
      detail = null;

  factory GlanceCheck.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const GlanceCheck.miss(GlanceMiss.failed);
    final raw = m['bytes'];
    return GlanceCheck(
      miss: m['miss'] == null ? null : GlanceMissLabel.parse('${m['miss']}'),
      package: m['package'] as String?,
      label: m['label'] as String?,
      bytes: raw is Uint8List ? raw : null,
      detail: m['detail'] as String?,
    );
  }

  bool get ok => miss == null;

  /// 给模型和给人看的「她在用什么」。名字查不到就用包名。
  String? get appName => label ?? package;
}
