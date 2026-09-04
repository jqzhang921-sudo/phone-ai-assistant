import 'dart:async';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「她刚才在用什么」——只有名字和时长，没有内容。
///
/// 这条路是拿来替代截屏的。截屏要把整块屏幕传到模型那边才看得懂，等于把微信
/// 内容、余额、半夜搜的东西一起传出去；这里拿到的是「微信 40 分钟」这种，
/// 传出去的就这么多。能力小得多，而「她今天很晚还没睡」这类感知足够了。
///
/// **不当开口的由头，只当背景和刹车。** 接成由头的话，它第一句大概率是
/// 「你今天刷了三小时抖音哦」——那正是人设里明令禁止的「复述 TA 的状态」。
class AppUsage {
  static const _channel = MethodChannel('app_usage');
  static const _excludedKey = 'app_usage_excluded';

  /// 「查看使用情况」的权限开了没。
  ///
  /// 这个权限要不来——只能问状态，然后把人送去系统设置（[openSettings]）。
  /// 任何时候都可能被用户在设置里收回，所以每次用之前都要问，不能缓存。
  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false; // 不是安卓
    }
  }

  /// 打开系统的「有权查看使用情况的应用」那一页。
  static Future<bool> openSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 查一段时间里各个 app 用了多久，已经按排除名单过滤，长的排前面。
  ///
  /// 没权限就返回空表，不抛——调用方（记忆、主动说话）都是「有就用、没有就
  /// 算了」，为这个中断一整条流程不值得。
  static Future<List<AppUsageEntry>> query({
    required DateTime start,
    required DateTime end,
  }) async {
    final List<dynamic> raw;
    try {
      raw =
          await _channel
              .invokeMethod<List<dynamic>>('query', {
                'start': start.millisecondsSinceEpoch,
                'end': end.millisecondsSinceEpoch,
              })
              // 这个调用在**发消息的主路上**（记忆上下文每轮都要拼）。平台通道
              // 卡住的话没有任何东西会把它叫醒，症状是消息发不出去、界面干等，
              // 而且看不出跟「用了哪个 app」有关系。宁可当作没读到。
              //
              // 在没装 TestWidgetsFlutterBinding 的单元测试里，这个调用**真的会
              // 永远挂着**——不是抛 MissingPluginException，是不返回。
              .timeout(const Duration(seconds: 3), onTimeout: () => const []) ??
          const [];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }

    final excluded = await excludedPackages();
    return raw
        .whereType<Map>()
        .map((m) => AppUsageEntry.fromMap(Map<String, dynamic>.from(m)))
        .where((e) => !excluded.contains(e.package))
        .toList();
  }

  /// 不想让它知道的那些 app。
  ///
  /// 光是名字有时候就够说明问题了（约会的、看病的、找工作的）。所以这道闸
  /// 在她手上：名单里的包，[query] 当它们不存在——不是标记成「已隐藏」再传
  /// 出去，是根本不出现。
  static Future<Set<String>> excludedPackages() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_excludedKey) ?? const []).toSet();
  }

  static Future<void> setExcluded(Set<String> packages) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_excludedKey, packages.toList()..sort());
  }

  static Future<void> exclude(String package) async {
    final now = await excludedPackages();
    await setExcluded({...now, package});
  }

  static Future<void> unexclude(String package) async {
    final now = await excludedPackages();
    await setExcluded(now.where((p) => p != package).toSet());
  }
}

class AppUsageEntry {
  final String package;

  /// 看得懂的名字。查不到时是包名本身，不是「未知应用」——排除名单按包名存，
  /// 界面上总得让人认出这一条是谁。
  final String label;

  final Duration total;
  final DateTime lastUsed;

  const AppUsageEntry({
    required this.package,
    required this.label,
    required this.total,
    required this.lastUsed,
  });

  factory AppUsageEntry.fromMap(Map<String, dynamic> m) => AppUsageEntry(
    package: '${m['package']}',
    label: '${m['label'] ?? m['package']}',
    total: Duration(milliseconds: (m['totalMs'] as num?)?.toInt() ?? 0),
    lastUsed: DateTime.fromMillisecondsSinceEpoch(
      (m['lastUsed'] as num?)?.toInt() ?? 0,
    ),
  );

  /// 给模型看的一行。**只说名字和时长**，别的什么都不给。
  String get line => '$label ${_readable(total)}';

  static String _readable(Duration d) {
    if (d.inMinutes < 1) return '不到一分钟';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    final h = d.inMinutes ~/ 60;
    final m = d.inMinutes % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  }
}
