import 'package:android_intent_plus/android_intent.dart';

import '../../models/mcp_tool.dart';

/// 闹钟、倒计时、日历——**交给系统应用去做，不自己实现**。
///
/// 这一点是有意的。App 自己起后台定时器在这台机器上不可靠：国产 ROM 会杀
/// 后台进程，息屏一会儿就没了，闹钟静默不响。而一个不会响的提醒比没有提醒
/// 更糟——你会开始依赖它。
///
/// 发 intent 交给系统时钟 / 日历之后，定时归系统管：那些应用天然在白名单里，
/// 不可能被杀。代价是提醒不长在这个 App 里，但换来的是它真的会响。
///
/// 相应地，**这里只能「加」，不能「查」和「删」**：Android 没有列出或删除
/// 闹钟的标准 intent（`SHOW_ALARMS` 只能把时钟应用打开）。用户要改要删，
/// 去时钟应用里操作。工具描述里得说清楚，别让模型答应它做不到的事。
class AlarmTool {
  static McpTool get definition => McpTool(
    name: 'set_alarm',
    description:
        '在用户手机的系统时钟里定一个闹钟。'
        '**只在用户明确要你定的时候用**——凌晨响一个没人要的闹钟是很讨厌的事。'
        '定好之后告诉用户几点、什么标签。'
        '注意：你只能定，不能查也不能删（Android 没有这样的接口），'
        '用户要改要删得自己去时钟应用里操作，别答应帮 TA 删。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'hour': {'type': 'integer', 'description': '几点，24 小时制，0–23。'},
        'minute': {'type': 'integer', 'description': '几分，0–59。'},
        'label': {
          'type': 'string',
          'description': '闹钟标签，一句话说清是为了什么，比如「喝水」「该睡了」。',
        },
        'weekdays': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description':
              '重复的星期，1=周一 … 7=周日。不填就是只响一次。'
              '比如工作日每天填 [1,2,3,4,5]。',
        },
      },
      'required': ['hour', 'minute', 'label'],
    },
    category: '手机工具',
  );

  /// Android 的 `Calendar.DAY_OF_WEEK`：周日=1、周一=2 … 周六=7。
  /// 工具对外用「1=周一」这种人话，这里转一次。
  static int _toAndroidDay(int isoDay) => isoDay == 7 ? 1 : isoDay + 1;

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final hour = _asInt(args['hour']);
      final minute = _asInt(args['minute']);
      final label = (args['label'] as String?)?.trim();

      if (hour == null || hour < 0 || hour > 23) {
        return {'success': false, 'error': 'hour 必须是 0–23 的整数'};
      }
      if (minute == null || minute < 0 || minute > 59) {
        return {'success': false, 'error': 'minute 必须是 0–59 的整数'};
      }
      if (label == null || label.isEmpty) {
        return {'success': false, 'error': '缺少 label（闹钟标签）'};
      }

      final rawDays = args['weekdays'];
      final days = <int>[];
      if (rawDays is List) {
        for (final d in rawDays) {
          final n = _asInt(d);
          if (n == null || n < 1 || n > 7) {
            return {'success': false, 'error': 'weekdays 里只能是 1–7（1=周一）'};
          }
          days.add(_toAndroidDay(n));
        }
      }

      await AndroidIntent(
        action: 'android.intent.action.SET_ALARM',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.HOUR': hour,
          'android.intent.extra.alarm.MINUTES': minute,
          'android.intent.extra.alarm.MESSAGE': label,
          // 静默设置，不跳出这个 App 去时钟界面——
          // 用户要的正是「不用跳出去」
          'android.intent.extra.alarm.SKIP_UI': true,
          if (days.isNotEmpty) 'android.intent.extra.alarm.DAYS': days,
        },
      ).launch();

      final hhmm =
          '${hour.toString().padLeft(2, '0')}:'
          '${minute.toString().padLeft(2, '0')}';
      return {
        'success': true,
        'time': hhmm,
        'label': label,
        'repeat': days.isEmpty ? '只响一次' : '每周重复',
        'message': '闹钟定好了：$hhmm「$label」。在系统时钟里能看到，要改要删去那儿。',
      };
    } catch (e) {
      return {'success': false, 'error': '定闹钟失败：$e。可能是这台机器的时钟应用不认标准 intent。'};
    }
  }
}

/// 倒计时。和闹钟分开：用户说「二十分钟后提醒我」时，
/// 模型不用先去算那是几点几分——算错了就是响错时间。
class TimerTool {
  static McpTool get definition => McpTool(
    name: 'set_timer',
    description:
        '在系统时钟里起一个倒计时。'
        '用户说「多久之后提醒我」时用这个，不要自己换算成几点几分再去定闹钟——'
        '换算容易错。同样只在用户明确要求时用。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'seconds': {'type': 'integer', 'description': '倒计时多少秒。'},
        'label': {'type': 'string', 'description': '倒计时标签，比如「面条好了」。'},
      },
      'required': ['seconds', 'label'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final seconds = _asInt(args['seconds']);
      final label = (args['label'] as String?)?.trim();
      if (seconds == null || seconds <= 0) {
        return {'success': false, 'error': 'seconds 必须是正整数'};
      }
      if (label == null || label.isEmpty) {
        return {'success': false, 'error': '缺少 label（倒计时标签）'};
      }

      await AndroidIntent(
        action: 'android.intent.action.SET_TIMER',
        arguments: <String, dynamic>{
          'android.intent.extra.alarm.LENGTH': seconds,
          'android.intent.extra.alarm.MESSAGE': label,
          'android.intent.extra.alarm.SKIP_UI': true,
        },
      ).launch();

      final mins = (seconds / 60).round();
      return {
        'success': true,
        'message': '倒计时起好了：${mins >= 1 ? '$mins 分钟' : '$seconds 秒'}「$label」。',
      };
    } catch (e) {
      return {'success': false, 'error': '起倒计时失败：$e'};
    }
  }
}

/// 往系统日历加一件事。
///
/// 和闹钟不同，这个**故意打开日历的新建页面让用户确认**，不静默写入：
/// 日历是长期的、会同步到别处的东西，悄悄往里塞条目越界了。
/// 字段已经填好，用户点一下保存就行。
class CalendarTool {
  static McpTool get definition => McpTool(
    name: 'add_calendar_event',
    description:
        '往用户的系统日历里加一件事。会打开日历的新建页面、字段填好，'
        '**由用户自己点保存**——不会替 TA 存。'
        '所以告诉用户「已经填好了，你确认一下」，不要说「已经加进日历了」。'
        '时间用 ISO 8601，比如 2026-08-22T19:30:00。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': '事情的标题。'},
        'begin': {'type': 'string', 'description': '开始时间，ISO 8601。'},
        'end': {'type': 'string', 'description': '结束时间，ISO 8601。不填按开始后一小时算。'},
        'location': {'type': 'string', 'description': '地点，可选。'},
        'description': {'type': 'string', 'description': '备注，可选。'},
      },
      'required': ['title', 'begin'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final title = (args['title'] as String?)?.trim();
      if (title == null || title.isEmpty) {
        return {'success': false, 'error': '缺少 title'};
      }
      final begin = DateTime.tryParse((args['begin'] as String?) ?? '');
      if (begin == null) {
        return {
          'success': false,
          'error': 'begin 解析不了，要 ISO 8601，比如 2026-08-22T19:30:00',
        };
      }
      final end =
          DateTime.tryParse((args['end'] as String?) ?? '') ??
          begin.add(const Duration(hours: 1));

      await AndroidIntent(
        action: 'android.intent.action.INSERT',
        data: 'content://com.android.calendar/events',
        arguments: <String, dynamic>{
          'title': title,
          'beginTime': begin.millisecondsSinceEpoch,
          'endTime': end.millisecondsSinceEpoch,
          if ((args['location'] as String?)?.trim().isNotEmpty ?? false)
            'eventLocation': (args['location'] as String).trim(),
          if ((args['description'] as String?)?.trim().isNotEmpty ?? false)
            'description': (args['description'] as String).trim(),
        },
      ).launch();

      return {
        'success': true,
        'pending_confirm': true,
        'message':
            '日历的新建页面已经打开，「$title」的时间地点都填好了，'
            '等用户自己点保存。别说成已经加好了。',
      };
    } catch (e) {
      return {'success': false, 'error': '打开日历失败：$e'};
    }
  }
}

int? _asInt(Object? v) => switch (v) {
  int n => n,
  String s => int.tryParse(s),
  double d => d.round(),
  _ => null,
};
