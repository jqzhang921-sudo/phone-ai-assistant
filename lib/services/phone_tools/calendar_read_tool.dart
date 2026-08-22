import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/settings.dart';
import '../../main.dart' show appNavigatorKey;
import '../../models/mcp_tool.dart';

/// 读系统日历。
///
/// 为什么在 Android 权限之上又加一层开关：
///
/// `READ_CALENDAR` 是一次性授权——给过之后系统不再过问，App 想读随时读。
/// 但这个工具读到的东西会**作为返回值发给模型**，也就是离开这台手机。
/// 日历里可能有医院预约、别人的名字、和这个 App 完全无关的安排；
/// 收藏和日记是用户自己写在这个 App 里的，日历不是。
///
/// 读的实现是自己查 ContentProvider（`CalendarChannel.kt`），不用
/// device_calendar 插件——那个插件要 `WRITE && READ` 才肯读，为了读而
/// 声明写权限是多余的授权。
///
/// 所以策略归用户：每次问（默认）/ 一直允许 / 不允许。
/// 保守的默认值比省事重要——用户可以在弹框里一键升级成「一直允许」，
/// 但反过来（默认放行、事后才发现）就晚了。
class CalendarReadTool {
  static const _channel = MethodChannel('calendar_reader');

  /// 一次最多看多少天。范围越大，一次发出去的私人信息越多。
  static const _maxDays = 31;

  /// 没人点弹框就当拒绝。MCP server 也会从电脑那边调这批工具，
  /// 那时人不在手机前面，不设超时会一直挂着。
  static const _askTimeout = Duration(seconds: 60);

  static McpTool get definition => McpTool(
    name: 'list_calendar_events',
    description:
        '看用户系统日历里某段时间的安排。'
        '用户问「我明天有什么事」「这周几有空」，或者你要帮 TA 加日程、'
        '想先看看有没有撞上时，用这个。'
        '每次读都可能要用户当场点头同意（取决于 TA 的设置），'
        '所以别为了闲聊反复读；一次问清一个范围。'
        '被拒绝了就说「你没让我看日历」，不要猜 TA 的安排。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'start': {
          'type': 'string',
          'description': '起始日期，ISO 8601，比如 2026-08-22。不填按今天算。',
        },
        'days': {
          'type': 'integer',
          'description': '从起始日往后看几天，默认 7，最多 $_maxDays。',
        },
      },
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final start =
          DateTime.tryParse((args['start'] as String?) ?? '') ?? DateTime.now();
      final rawDays = args['days'];
      final days = switch (rawDays) {
        int n => n.clamp(1, _maxDays),
        String s => (int.tryParse(s) ?? 7).clamp(1, _maxDays),
        _ => 7,
      };
      final from = DateTime(start.year, start.month, start.day);
      final to = from.add(Duration(days: days));

      final allowed = await _checkAccess(from, to);
      if (allowed != null) return allowed; // 拒绝时直接返回说明

      // 权限申请在原生侧做：没给就弹系统框，给了直接返回数据
      final List<dynamic> raw;
      try {
        raw =
            await _channel.invokeMethod<List<dynamic>>('listEvents', {
              'start': from.millisecondsSinceEpoch,
              'end': to.millisecondsSinceEpoch,
            }) ??
            const [];
      } on PlatformException catch (e) {
        if (e.code == 'PERMISSION') {
          return {
            'success': false,
            'error': '用户没给系统的日历权限。要看的话请 TA 在手机的应用权限里放开「日历」。',
          };
        }
        rethrow;
      }

      final events = <Map<String, dynamic>>[];
      for (final item in raw) {
        final m = Map<String, dynamic>.from(item as Map);
        final begin = DateTime.fromMillisecondsSinceEpoch(m['begin'] as int);
        final end = DateTime.fromMillisecondsSinceEpoch(m['end'] as int);
        final loc = (m['location'] as String?)?.trim();
        events.add({
          'title':
              (m['title'] as String?)?.trim().isNotEmpty == true
                  ? m['title']
                  : '(无标题)',
          'start': begin.toIso8601String(),
          'end': end.toIso8601String(),
          'all_day': m['allDay'] == true,
          if (loc != null && loc.isNotEmpty) 'location': loc,
        });
      }

      return {
        'success': true,
        'range': '${_d(from)} 到 ${_d(to)}',
        'total': events.length,
        'events': events,
        if (events.isEmpty) 'note': '这段时间日历里是空的——如实说没有安排，不要编。',
      };
    } catch (e) {
      return {'success': false, 'error': '读日历失败：$e'};
    }
  }

  /// 返回 null 表示放行；返回 Map 表示拒绝，直接当结果给模型。
  static Future<Map<String, dynamic>?> _checkAccess(
    DateTime from,
    DateTime to,
  ) async {
    final settings = await AppSettings.load();
    switch (settings.calendarAccess) {
      case CalendarAccess.never:
        return {
          'success': false,
          'error': '用户把「查看日历」设成了不允许。想看的话请 TA 去设置里改，别反复试。',
        };
      case CalendarAccess.always:
        return null;
      case CalendarAccess.ask:
        final choice = await _ask(from, to);
        if (choice == _AskResult.allowAlways) {
          settings.calendarAccess = CalendarAccess.always;
          await settings.save();
          return null;
        }
        if (choice == _AskResult.allowOnce) return null;
        return {'success': false, 'error': '用户这次没让你看日历。就说你没看到，不要猜 TA 的安排。'};
    }
  }

  static Future<_AskResult> _ask(DateTime from, DateTime to) async {
    final ctx = appNavigatorKey.currentContext;
    // 人不在前台（比如电脑那边通过 MCP 调过来），没法问，按拒绝
    if (ctx == null) return _AskResult.deny;

    final result = await showDialog<_AskResult>(
      context: ctx,
      builder:
          (dialogCtx) => AlertDialog(
            title: const Text('看一下你的日历？'),
            content: Text(
              '它想看 ${_d(from)} 到 ${_d(to)} 的安排。\n\n'
              '这段时间的日程会发给模型——和收藏、日记不同，'
              '那是你写在别处的东西。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(_AskResult.deny),
                child: const Text('不允许'),
              ),
              TextButton(
                onPressed:
                    () => Navigator.of(dialogCtx).pop(_AskResult.allowAlways),
                child: const Text('一直允许'),
              ),
              FilledButton(
                onPressed:
                    () => Navigator.of(dialogCtx).pop(_AskResult.allowOnce),
                child: const Text('这次允许'),
              ),
            ],
          ),
    ).timeout(_askTimeout, onTimeout: () => _AskResult.deny);

    return result ?? _AskResult.deny;
  }

  static String _d(DateTime t) => '${t.month} 月 ${t.day} 日';
}

enum _AskResult { deny, allowOnce, allowAlways }
