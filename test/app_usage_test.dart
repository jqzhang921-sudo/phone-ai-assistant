import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:phone_ai_assistant/services/app_usage.dart';

/// 排除名单是这块唯一由她直接控制的东西，所以重点测它：名单里的包**根本不
/// 出现**，不是标一下再传出去。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app_usage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<Map<String, Object>> fakeRows = [];
  String? failWith;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    failWith = null;
    fakeRows = [
      {
        'package': 'com.tencent.mm',
        'label': '微信',
        'totalMs': 40 * 60 * 1000,
        'lastUsed': 1788000000000,
      },
      {
        'package': 'com.ss.android.ugc.aweme',
        'label': '抖音',
        'totalMs': 2 * 60 * 60 * 1000,
        'lastUsed': 1788000100000,
      },
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (failWith != null) throw PlatformException(code: failWith!);
      switch (call.method) {
        case 'hasPermission':
          return true;
        case 'query':
          return fakeRows;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<List<String>> labels() async {
    final r = await AppUsage.query(
      start: DateTime(2026, 9, 4),
      end: DateTime(2026, 9, 5),
    );
    return r.map((e) => e.label).toList();
  }

  test('正常读得到，字段解析对', () async {
    final r = await AppUsage.query(
      start: DateTime(2026, 9, 4),
      end: DateTime(2026, 9, 5),
    );
    expect(r.first.label, '微信');
    expect(r.first.total, const Duration(minutes: 40));
    expect(r.first.package, 'com.tencent.mm');
  });

  test('排除名单里的包根本不出现', () async {
    await AppUsage.exclude('com.tencent.mm');
    expect(await labels(), ['抖音']);
  });

  test('取消排除之后又回来了', () async {
    await AppUsage.exclude('com.tencent.mm');
    await AppUsage.unexclude('com.tencent.mm');
    expect(await labels(), containsAll(['微信', '抖音']));
  });

  test('排除名单能存能读', () async {
    await AppUsage.setExcluded({'b.pkg', 'a.pkg'});
    expect(await AppUsage.excludedPackages(), {'a.pkg', 'b.pkg'});
  });

  // 记忆和主动说话都是「有就用、没有就算了」，不该为这个中断整条流程。
  test('没权限时返回空表，不抛', () async {
    failWith = 'NO_PERMISSION';
    expect(await labels(), isEmpty);
  });

  test('不是安卓（没有这个 channel）也不抛', () async {
    messenger.setMockMethodCallHandler(channel, null);
    expect(await labels(), isEmpty);
    expect(await AppUsage.hasPermission(), isFalse);
  });

  group('给模型看的那一行', () {
    AppUsageEntry entry(int minutes) => AppUsageEntry(
      package: 'p',
      label: '某 app',
      total: Duration(minutes: minutes),
      lastUsed: DateTime(2026, 9, 4),
    );

    test('不到一分钟不说 0 分钟', () {
      expect(entry(0).line, '某 app 不到一分钟');
    });

    test('整小时不拖一个 0 分', () {
      expect(entry(120).line, '某 app 2 小时');
    });

    test('带零头的写成几小时几分', () {
      expect(entry(95).line, '某 app 1 小时 35 分');
    });
  });
}
