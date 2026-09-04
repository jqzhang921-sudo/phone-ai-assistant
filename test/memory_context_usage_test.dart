import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/app_usage.dart';
import 'package:phone_ai_assistant/services/memory_context.dart';

/// 使用情况这一段进上下文的规矩。
///
/// 其余几段（日记、书、信）在测试里读不到文件系统会被各自的 catch 吞掉，
/// 所以这里断言的就是这一段自己。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app_usage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<Map<String, Object>> rows = [];
  bool available = true;

  Map<String, Object> row(String pkg, String label, int minutes) => {
    'package': pkg,
    'label': label,
    'totalMs': minutes * 60 * 1000,
    'lastUsed': 1788000000000,
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    available = true;
    rows = [
      row('com.xingin.xhs', '小红书', 107),
      row('com.tencent.mm', '微信', 55),
      row('com.a', '划一眼就退的', 2),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (!available) throw PlatformException(code: 'NO_PERMISSION');
      if (call.method == 'query') return rows;
      if (call.method == 'hasPermission') return true;
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('用过的 app 带着时长进上下文', () async {
    final ctx = await buildMemoryContext();
    expect(ctx, contains('TA 今天用过的 app'));
    expect(ctx, contains('小红书 1 小时 47 分'));
    expect(ctx, contains('微信 55 分钟'));
  });

  // 系统会把每个前台过的包都列出来，划一眼就退的没有信息量。
  test('不到 5 分钟的不算「在用」', () async {
    final ctx = await buildMemoryContext();
    expect(ctx, isNot(contains('划一眼就退的')));
  });

  // 这一段天然长得像「今日报告」，模型看见就想念出来。
  test('必须带着「别念出来」那条约束', () async {
    final ctx = await buildMemoryContext();
    expect(ctx, contains('这不是话题，是分寸'));
    expect(ctx, contains('别评论她用了多久'));
  });

  test('排除名单里的不进上下文', () async {
    await AppUsage.exclude('com.tencent.mm');
    final ctx = await buildMemoryContext();
    expect(ctx, contains('小红书'));
    expect(ctx, isNot(contains('微信')));
  });

  test('没权限时整段不出现，也不抛', () async {
    available = false;
    final ctx = await buildMemoryContext();
    expect(ctx, isNot(contains('TA 今天用过的 app')));
  });

  test('全都不够 5 分钟时整段不出现', () async {
    rows = [row('com.a', '甲', 1), row('com.b', '乙', 4)];
    final ctx = await buildMemoryContext();
    expect(ctx, isNot(contains('TA 今天用过的 app')));
  });
}
