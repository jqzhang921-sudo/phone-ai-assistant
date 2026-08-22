import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:phone_ai_assistant/screens/memory_screen.dart';

/// AppSettings.load() 会读 flutter_secure_storage（ElevenLabs key），
/// 测试环境没有插件实现，不打桩就抛 MissingPluginException。
void _mockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
}

/// ListView 只给可见的孩子建元素，屏幕外的 find 不到。
/// 把视口调到足够高，整页一次装下。
Future<void> _tallViewport(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 6000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('记忆页：渲染、名字、排版/原文切换', (tester) async {
    _mockSecureStorage();

    final now = DateTime(2026, 8, 22);
    SharedPreferences.setMockInitialValues({
      'user_name': 'Cleo',
      'ai_name': '沐',
      'diary_entries': jsonEncode([
        for (var i = 0; i < 17; i++)
          {
            'id': 'd$i',
            'date': now.subtract(Duration(days: i)).toIso8601String(),
            'content': '第 $i 篇日记。今天聊了记忆怎么做，她说看不见它记着什么。',
            'createdAt': now.subtract(Duration(days: i)).toIso8601String(),
          },
      ]),
      'favorited_musings': jsonEncode([
        for (var i = 0; i < 16; i++)
          {
            'id': 'm$i',
            'date': now.subtract(Duration(days: i * 2)).toIso8601String(),
            'content': '第 $i 条收藏的话，长一些，用来看看八十字截断之后这一行有多长。',
            'createdAt': now.subtract(Duration(days: i * 2)).toIso8601String(),
            'source': ['musing', 'ai', 'user'][i % 3],
            'savedBy': ['user', 'ai', 'both'][i % 3],
            if (i == 2) 'note': '她长按写的备注',
          },
      ]),
      'bookshelf_books': jsonEncode([]),
    });

    await _tallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('记忆'), findsOneWidget);
    expect(find.textContaining('每次和它说话'), findsOneWidget);
    expect(find.textContaining('它叫沐'), findsOneWidget);
    expect(find.textContaining('它知道你叫Cleo'), findsOneWidget);
    expect(find.textContaining('每轮都要重发一次'), findsOneWidget);
    // 顶部要把「常驻」和「每轮重付」分开报——成本的形状本来就是两截
    expect(find.textContaining('跟人设待在一起'), findsOneWidget);
    expect(find.text('这一轮带过来的记录'), findsOneWidget);
    // 排版视图里不该再出现 markdown 标记
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);

    await tester.tap(find.byType(IconButton).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('## 你在哪儿'), findsOneWidget);
  });

  testWidgets('记忆页：默认只显示摘要，点开才看到细节', (tester) async {
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({
      'user_name': 'Cleo',
      'ai_name': '沐',
      'diary_entries': jsonEncode([]),
      'favorited_musings': jsonEncode([]),
      'bookshelf_books': jsonEncode([]),
      'memory_facts': jsonEncode([
        {
          'id': 'aaaaaaaa-1111-2222-3333-444444444444',
          'category': 'profile',
          'name': '怎么称呼',
          'summary': 'TA 的名字和不喜欢的叫法',
          'details': ['叫 Cleo', '不喜欢被叫全名'],
          'source': 'user',
          'pinned': true,
          'createdAt': '2026-08-20T10:00:00.000',
          'updatedAt': '2026-08-20T10:00:00.000',
        },
        {
          'id': 'bbbbbbbb-1111-2222-3333-444444444444',
          'category': 'rapport',
          'name': '说话方式',
          'summary': 'TA 希望你怎么跟 TA 说话',
          'details': ['不喜欢被哄，出了问题直接说'],
          'source': 'ai',
          'pinned': false,
          'createdAt': '2026-08-21T10:00:00.000',
          'updatedAt': '2026-08-21T10:00:00.000',
        },
      ]),
    });

    await _tallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('关于你'), findsOneWidget);
    expect(find.text('关于 TA'), findsOneWidget);
    expect(find.text('相处方式'), findsOneWidget);

    // 名字和摘要在，细节**不在**——这是这一版的全部要点
    expect(find.text('怎么称呼'), findsOneWidget);
    expect(find.text('TA 的名字和不喜欢的叫法'), findsOneWidget);
    expect(find.text('叫 Cleo'), findsNothing);
    expect(find.text('不喜欢被叫全名'), findsNothing);
    expect(find.textContaining('2 条细节'), findsOneWidget);

    // 点开才出现
    await tester.tap(find.text('怎么称呼'));
    await tester.pumpAndSettle();
    expect(find.text('叫 Cleo'), findsOneWidget);
    expect(find.text('不喜欢被叫全名'), findsOneWidget);
    // 另一条没点，仍然是收起的
    expect(find.text('不喜欢被哄，出了问题直接说'), findsNothing);

    expect(find.textContaining('还是空的'), findsNothing);
  });

  testWidgets('记忆页：旧的扁平数据能读出来，不整条丢掉', (tester) async {
    _mockSecureStorage();
    SharedPreferences.setMockInitialValues({
      'user_name': 'Cleo',
      'ai_name': '沐',
      'diary_entries': jsonEncode([]),
      'favorited_musings': jsonEncode([]),
      'bookshelf_books': jsonEncode([]),
      // 扁平版（MemoryFact）的形状：只有 content + why，没有 name/summary/details
      'memory_facts': jsonEncode([
        {
          'id': 'cccccccc-1111-2222-3333-444444444444',
          'category': 'interest',
          'content': '在写一个陪伴型的 Flutter App',
          'why': 'TA 自己说的',
          'source': 'user',
          'pinned': false,
          'createdAt': '2026-08-22T10:00:00.000',
          'updatedAt': '2026-08-22T10:00:00.000',
        },
      ]),
    });

    await _tallViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();

    // content 落到 summary，条目本身没丢
    expect(find.text('在写一个陪伴型的 Flutter App'), findsOneWidget);
    // 没有 name 时兜底成「未命名」，而不是空白或崩掉
    expect(find.text('未命名'), findsOneWidget);
    // why 不该丢——它进了细节
    expect(find.textContaining('1 条细节'), findsOneWidget);
    await tester.tap(find.text('未命名'));
    await tester.pumpAndSettle();
    expect(find.text('TA 自己说的'), findsOneWidget);
  });
}
