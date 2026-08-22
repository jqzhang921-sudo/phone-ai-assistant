import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:phone_ai_assistant/screens/memory_screen.dart';

void main() {
  testWidgets('记忆页：渲染、名字、排版/原文切换', (tester) async {
    // AppSettings.load() 会读 flutter_secure_storage（ElevenLabs key），
    // 测试环境没有插件实现，不打桩就抛 MissingPluginException。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );

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

    // ListView 只给可见的孩子建元素，屏幕外的 find 不到。
    // 把视口调到足够高，整页一次装下。
    await tester.binding.setSurfaceSize(const Size(1000, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('记忆'), findsOneWidget);
    expect(find.textContaining('每次和它说话'), findsOneWidget);
    // 顶部那句要报出名字和字数
    expect(find.textContaining('它叫沐'), findsOneWidget);
    expect(find.textContaining('它知道你叫Cleo'), findsOneWidget);
    expect(find.textContaining('字，每轮都要重发'), findsOneWidget);
    // 章节标题被渲染成了标题（## 已剥掉）
    expect(find.text('你写下的日记'), findsOneWidget);
    expect(find.text('一隅里收藏的话'), findsOneWidget);
    // 排版视图里不该再出现 markdown 标记
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('**'), findsNothing);

    // 切到原文
    await tester.tap(find.byType(IconButton).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('## 你在哪儿'), findsOneWidget);
  });

  testWidgets('记忆页：稳定事实按分类分组，钉住的标出来', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null,
        );

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
          'content': '叫 Cleo，不喜欢被叫全名',
          'why': 'TA 自己说的',
          'source': 'user',
          'pinned': true,
          'createdAt': '2026-08-20T10:00:00.000',
          'updatedAt': '2026-08-20T10:00:00.000',
        },
        {
          'id': 'bbbbbbbb-1111-2222-3333-444444444444',
          'category': 'rapport',
          'content': '不喜欢被哄，出了问题直接说',
          'why': '几次对话里 TA 都这么讲过',
          'source': 'ai',
          'pinned': false,
          'createdAt': '2026-08-21T10:00:00.000',
          'updatedAt': '2026-08-21T10:00:00.000',
        },
      ]),
    });

    await tester.binding.setSurfaceSize(const Size(1000, 6000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MaterialApp(home: MemoryScreen()));
    await tester.pumpAndSettle();

    expect(find.text('关于你'), findsOneWidget);
    // 两条分属不同分类，两个分类标题都该出现
    expect(find.text('关于 TA'), findsOneWidget);
    expect(find.text('相处方式'), findsOneWidget);
    expect(find.text('叫 Cleo，不喜欢被叫全名'), findsOneWidget);
    expect(find.text('不喜欢被哄，出了问题直接说'), findsOneWidget);
    // 来源和 why 要摆在一起——一条不认识的事实，光看内容判断不了真假
    expect(find.textContaining('你说的 · TA 自己说的'), findsOneWidget);
    expect(find.textContaining('它自己记的 · 几次对话里'), findsOneWidget);
    // 空态那句在有数据时不该出现
    expect(find.textContaining('还是空的'), findsNothing);
  });
}
