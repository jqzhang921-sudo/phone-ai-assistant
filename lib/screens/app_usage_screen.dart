import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../services/app_usage.dart';

/// 「它能知道你在用什么」。
///
/// 这一页存在的理由不是配置，是**让她看见它到底读到了什么**。这类功能最容易
/// 让人不安的地方是「我不知道它知道多少」，所以列表照原样摊开：读到几条就是
/// 几条，一条不藏。
///
/// 每行右边那个开关关掉 = 这个 app 从此不出现在它眼前。不是标成「已隐藏」再
/// 传过去——是 [AppUsage.query] 里根本不返回。
class AppUsageScreen extends StatefulWidget {
  const AppUsageScreen({super.key});

  @override
  State<AppUsageScreen> createState() => _AppUsageScreenState();
}

class _AppUsageScreenState extends State<AppUsageScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _granted = false;
  List<AppUsageEntry> _visible = const [];
  Set<String> _excluded = {};

  /// 被排除的那些也要显示出来（灰着、开关关掉），否则关掉之后整行消失，
  /// 想再打开都找不着地方。所以这里单独留一份没过滤的。
  List<AppUsageEntry> _all = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 权限是在系统设置里开的，人回来的时候必须重查一遍——不然她开完权限回到
  /// 这一页，看到的还是「还没开启」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final granted = await AppUsage.hasPermission();
    if (!granted) {
      if (!mounted) return;
      setState(() {
        _granted = false;
        _loading = false;
        _all = const [];
        _visible = const [];
      });
      return;
    }

    final now = DateTime.now();
    final excluded = await AppUsage.excludedPackages();
    // 从今天零点算起：和「今天过得怎么样」对得上，也不用她理解什么滚动窗口。
    final visible = await AppUsage.query(
      start: DateTime(now.year, now.month, now.day),
      end: now,
    );

    if (!mounted) return;
    setState(() {
      _granted = true;
      _loading = false;
      _excluded = excluded;
      _visible = visible;
      // query 已经滤过一遍，被排除的那些要单独补回来才看得见。
      _all = visible;
    });
    await _loadExcludedRows(excluded);
  }

  /// 把被排除的那几行也捞出来。
  ///
  /// 多查一次而不是让 [AppUsage.query] 加个「不过滤」的开关：那个开关一旦存在，
  /// 迟早有人在别处调用时顺手打开，排除名单就形同虚设。界面自己多跑一趟，
  /// 换的是「不过滤」这条路只存在于界面里。
  Future<void> _loadExcludedRows(Set<String> excluded) async {
    if (excluded.isEmpty) return;
    final now = DateTime.now();
    final saved = excluded;
    await AppUsage.setExcluded({});
    final full = await AppUsage.query(
      start: DateTime(now.year, now.month, now.day),
      end: now,
    );
    await AppUsage.setExcluded(saved);
    if (!mounted) return;
    setState(() => _all = full);
  }

  Future<void> _toggle(String package, bool visibleToIt) async {
    if (visibleToIt) {
      await AppUsage.unexclude(package);
    } else {
      await AppUsage.exclude(package);
    }
    final now = await AppUsage.excludedPackages();
    if (!mounted) return;
    setState(() {
      _excluded = now;
      _visible = _all.where((e) => !now.contains(e.package)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('它能知道你在用什么')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _granted
              ? _list(theme)
              : _askPermission(theme),
    );
  }

  Widget _askPermission(ThemeData theme) {
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(
          PhosphorIconsRegular.hourglassMedium,
          size: 40,
          color: scheme.primary,
        ),
        const SizedBox(height: 16),
        Text('还没开启', style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        Text(
          '开启之后，它能知道你今天用了哪些 app、各用了多久。\n\n'
          '只有名字和时长，没有内容——它能知道你在微信里待了 40 分钟，'
          '不知道你说了什么。',
          style: TextStyle(height: 1.6, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            // messenger 在 await 之前取好：await 之后这个 State 可能已经没了，
            // 那时候再去拿 context 就是在用一个失效的引用。
            final messenger = ScaffoldMessenger.of(context);
            final ok = await AppUsage.openSettings();
            if (!ok) {
              messenger.showSnackBar(
                const SnackBar(content: Text('打不开系统设置，得手动去找「使用情况访问」')),
              );
            }
          },
          child: const Text('去系统设置里开启'),
        ),
        const SizedBox(height: 12),
        Text(
          '这个权限系统不让 app 自己申请，得你在设置里找到这个 app 手动打开。'
          '开完返回这一页会自动刷新。',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _list(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (_all.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            '今天还没有记录。\n系统攒够数据要一会儿，晚点再来看。',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(
          '这是它今天能看到的。关掉开关的那些，它那边根本不出现。',
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final e in _all) _row(theme, e),
        const SizedBox(height: 16),
        Text(
          '它看得见 ${_visible.length} 个，你挡掉了 ${_excluded.length} 个。',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _row(ThemeData theme, AppUsageEntry e) {
    final on = !_excluded.contains(e.package);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: on,
      onChanged: (v) => _toggle(e.package, v),
      title: Text(
        e.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: on ? null : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: Text(
        on ? e.line.replaceFirst('${e.label} ', '') : '它看不到这个',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
