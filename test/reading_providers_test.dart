import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读书版入口注册的 provider，必须覆盖它那些界面真正会读的。
///
/// ## 为什么要有这个测试
///
/// 2026-09-07 第一版为了「精简」只注册了三个 provider，结果聊天页在真机上
/// 整块变灰。原因是 MessageBubble 会 `context.watch<TtsService>()`，找不到
/// 就在 build 里抛异常——而 **release 模式下抛异常的 widget 渲染成一块纯灰**，
/// 不像 debug 那样显示红色报错框。看着像布局崩了，其实是缺依赖。
///
/// 这种错静态分析查不出来（provider 是运行时按类型找的），只有真机上才暴露，
/// 而且症状具有误导性。所以用一个纯文本扫描来兜住：
/// **界面里读了什么，入口就必须注册什么。**
void main() {
  test('读书版界面用到的 provider，main_reading 里都注册了', () {
    // 这些是读书版真正会打开的界面。别把主 App 的页面加进来——那些不在
    // 读书版的路由里，它们的依赖不该拖累这个入口。
    const screens = [
      'lib/screens/reading_shell.dart',
      'lib/screens/reading_home_screen.dart',
      'lib/screens/reading_notes_screen.dart',
      'lib/screens/reading_settings_screen.dart',
      'lib/screens/bookshelf_screen.dart',
      'lib/screens/book_chat_screen.dart',
      'lib/screens/book_discussion_screen.dart',
      'lib/screens/multi_book_chat_screen.dart',
      'lib/screens/reading_profile_screen.dart',
      'lib/screens/shared_text_sheet.dart',
      // 聊天页画出来的东西，依赖也算它的
      'lib/widgets/message_bubble.dart',
      'lib/widgets/chat_message_item.dart',
      'lib/widgets/tool_call_card.dart',
      'lib/widgets/app_surface.dart',
    ];

    final needed = <String>{};
    final pattern = RegExp(r'context\.(?:watch|read)<(\w+)>');
    for (final path in screens) {
      final file = File(path);
      if (!file.existsSync()) continue;
      for (final m in pattern.allMatches(file.readAsStringSync())) {
        needed.add(m.group(1)!);
      }
    }

    // 扫不到东西说明这个测试自己坏了（比如文件被改名），别假装通过。
    expect(needed, isNotEmpty, reason: '没扫到任何 provider，测试本身失效了');

    final entry = File('lib/main_reading.dart').readAsStringSync();
    final missing =
        needed.where((p) => !entry.contains('$p(')).toList()..sort();

    expect(
      missing,
      isEmpty,
      reason:
          '这些 provider 界面会读，但 main_reading.dart 没注册：$missing\n'
          '真机上的症状是「那一块渲染成纯灰」，不会报错，很难查。',
    );
  });
}
