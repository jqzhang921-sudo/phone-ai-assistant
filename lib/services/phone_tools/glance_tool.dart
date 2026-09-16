import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

import '../../models/mcp_tool.dart';
import '../capsule_texts.dart';
import '../chat_images.dart';
import '../screen_glance.dart';

/// 她的窗口是全屏的，还是悬浮窗 / 分屏。
///
/// 2026-09-15 Cleo 说聊天中途也想让它看一眼，理由是：「我可能并没有全屏打开
/// app 和它聊天，可能是开的悬浮窗，主屏幕是我在刷小红书」。全屏的时候截到的
/// 只是聊天页；小窗的时候屏幕大半是底下那个 App，马上截就有意义。
class GlanceWindow {
  /// 测试里换掉。
  static bool Function() floating = _floating;

  /// 窗口面积不到屏幕的八成就算小窗。键盘弹出来不改窗口大小（那是 inset），
  /// 横竖屏会把宽高对调，所以比面积不比边。
  static bool _floating() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final FlutterView v = views.first;
    final screen = v.display.size;
    final window = v.physicalSize;
    if (screen.isEmpty || window.isEmpty) return false;
    return window.width * window.height < screen.width * screen.height * 0.8;
  }
}

/// 聊天里的「你看看我在看什么」。
///
/// 和后台那条（`NudgeService._runGlance`）是两件事：那边是它自己好奇、先问它
/// 想不想看；这边是**她叫它看**，所以直接看。开关、锁屏、排除名单照样全管着。
class GlanceTool {
  /// 全屏时等她切出去最多等多久。**必须小于聊天里工具的 60 秒超时**
  /// （chat_screen 的 `_toolTimeout`），不然等到一半被掐掉，她切过去了却什么都没发生。
  static Duration maxWait = const Duration(seconds: 45);
  static Duration poll = const Duration(seconds: 1);

  static McpTool get definition => McpTool(
    name: 'glance_screen',
    description:
        '看一眼 TA 手机屏幕上现在是什么，截一张图给你。\n'
        'TA 叫你看（「你看看」「帮我看看这个」），或者你们正在聊 TA 手上正看着的东西时用。\n'
        'TA 要是全屏开着和你聊天，会等 TA 切到别的 App 再截（最多等 45 秒），'
        '所以调用之前先跟 TA 说一声让 TA 切过去；开着悬浮窗的话马上截。\n'
        '截到的图会留在对话里，TA 看得到。TA 没开「允许看一眼屏幕」就用不了。',
    inputSchema: {'type': 'object', 'properties': {}},
    category: '手机工具',
  );

  /// 看屏幕的整段（包括等她切出去的那最多 45 秒）都亮着流体云胶囊。
  /// 这条路是她叫它看的，但等待期间她人在别的 App 上，胶囊是她当场唯一看得见的痕迹。
  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) =>
      Capsule.whileGlancing(() => _execute(args));

  static Future<Map<String, dynamic>> _execute(Map<String, dynamic> args) async {
    if (!await ScreenGlance.allowed()) {
      return {
        'success': false,
        'error': 'TA 没开「允许看一眼屏幕」（设置 → 主动说话 → 看一眼屏幕），看不了。',
      };
    }

    // 全屏：等她离开聊天页。小窗：不用等。等的中途她打开了小窗，也算好了。
    if (!GlanceWindow.floating()) {
      final deadline = DateTime.now().add(maxWait);
      while (true) {
        final c = await ScreenGlance.check();
        if (c.ok) break;
        if (c.miss != GlanceMiss.inApp) return _missed(c.miss!);
        if (GlanceWindow.floating()) break;
        if (DateTime.now().isAfter(deadline)) {
          return {
            'success': false,
            'error': '等了 ${maxWait.inSeconds} 秒，TA 一直在聊天页上没切出去，所以没看。',
          };
        }
        await Future<void>.delayed(poll);
      }
    }

    final shot = await ScreenGlance.capture(allowInApp: GlanceWindow.floating());
    final bytes = shot.bytes;
    if (!shot.ok || bytes == null) return _missed(shot.miss ?? GlanceMiss.failed);

    final String ref;
    try {
      ref = await ChatImages.save(bytes);
    } catch (e) {
      return {'success': false, 'error': '截到了，但存不下来：$e'};
    }
    await ScreenGlance.markLooked(DateTime.now());

    return {
      'success': true,
      'app': shot.appName,
      'image': ref,
      'message':
          '截到了${shot.appName == null ? '' : '（TA 在用「${shot.appName}」）'}，'
          '图在下一条消息里。',
    };
  }

  static Map<String, dynamic> _missed(GlanceMiss miss) => {
    'success': false,
    'error': '没看成：${miss.label}',
  };
}
