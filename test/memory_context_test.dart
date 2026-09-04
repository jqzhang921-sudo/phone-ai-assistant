import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:phone_ai_assistant/services/memory_context.dart';

/// 日记正文按 diary_generator 里写死的「150~250 字」造，200 字取中间值。
/// 用真实长度造数据，量出来的字数才有参考价值。
String _body(String tag) => '$tag${'字' * 199}';

Map<String, dynamic> _diary(String id, String dateKey, String tag) => {
  'id': id,
  'date': '${dateKey}T09:00:00.000',
  'content': _body(tag),
  'createdAt': '${dateKey}T09:00:00.000',
};

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // buildMemoryContext 现在会去问「今天用了哪些 app」。这是个平台通道，
    // 在 testWidgets 的假时钟里既不会返回、也等不到 timeout 触发——整个测试
    // 就那么挂着。这里给它一个立刻回空表的桩，把这条支路从这些用例里摘掉：
    // 它自己的行为由 memory_context_usage_test 覆盖。
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('app_usage'),
      (call) async => call.method == 'query' ? <dynamic>[] : null,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('app_usage'),
      null,
    );
  });

  testWidgets('日记只给最近有日记的那一天，更早的不进上下文', (tester) async {
    final diaries = [
      // 最近一天写了两篇
      _diary('a', '2026-08-22', 'A'),
      _diary('b', '2026-08-22', 'B'),
      // 更早的每天一篇
      for (var i = 1; i <= 15; i++)
        _diary('d$i', '2026-08-${(21 - i + 1).toString().padLeft(2, '0')}', 'X$i'),
    ];
    SharedPreferences.setMockInitialValues({
      'diary_entries': jsonEncode(diaries),
      'favorited_musings': jsonEncode([]),
      'bookshelf_books': jsonEncode([]),
    });

    final ctx = await buildMemoryContext();

    // 最近那天的两篇都在
    expect(ctx.contains(_body('A')), isTrue);
    expect(ctx.contains(_body('B')), isTrue);
    // 前一天的不在——这是这次改动的全部意义
    expect(ctx.contains(_body('X1')), isFalse);
    // 但它得知道自己写过更早的，以及一共多少
    expect(ctx.contains('一共 17 篇'), isTrue);

    // 「更早的用 recall_records 翻」这类**固定说明**不该出现在这一段里。
    // 它们从不变，搬进了 memoryReadingRules（system 前缀，吃缓存）；
    // 留在这儿等于每轮重付一次。这条断言就是那次搬迁的回归保护。
    expect(ctx.contains('recall_records'), isFalse);
    expect(memoryReadingRules.contains('recall_records'), isTrue);

    // ignore: avoid_print
    print('=====按天取：${ctx.length} 字=====');
  });

  testWidgets('同一天写太多时按字数收口，但第一篇无条件给全', (tester) async {
    SharedPreferences.setMockInitialValues({
      'diary_entries': jsonEncode([
        for (var i = 1; i <= 4; i++) _diary('e$i', '2026-08-22', 'E$i'),
      ]),
      'favorited_musings': jsonEncode([]),
      'bookshelf_books': jsonEncode([]),
    });

    final ctx = await buildMemoryContext();

    // 200 + 200 = 400 还在预算内，加到第三篇就 600 超了 500，停在两篇
    expect(ctx.contains(_body('E1')), isTrue);
    expect(ctx.contains(_body('E2')), isTrue);
    expect(ctx.contains(_body('E3')), isFalse);
    // 收口了要说清楚，否则它以为那天就写了这些
    expect(ctx.contains('前 2 篇（那天共 4 篇）'), isTrue);
  });

  testWidgets('单篇超预算也要给全——半篇日记比没有更糟', (tester) async {
    SharedPreferences.setMockInitialValues({
      'diary_entries': jsonEncode([
        {
          'id': 'long',
          'date': '2026-08-22T09:00:00.000',
          'content': '长' * 900,
          'createdAt': '2026-08-22T09:00:00.000',
        },
      ]),
      'favorited_musings': jsonEncode([]),
      'bookshelf_books': jsonEncode([]),
    });

    final ctx = await buildMemoryContext();
    expect(ctx.contains('长' * 900), isTrue);
  });

  testWidgets('近期记录里只有数据，一句固定说明都不该留', (tester) async {
    SharedPreferences.setMockInitialValues({
      'diary_entries': jsonEncode([_diary('a', '2026-08-22', 'A')]),
      'favorited_musings': jsonEncode([
        {
          'id': 'm1',
          'date': '2026-08-22T10:00:00.000',
          'content': '一句收藏',
          'createdAt': '2026-08-22T10:00:00.000',
          'source': 'user',
          'savedBy': 'user',
        },
      ]),
      'bookshelf_books': jsonEncode([]),
      'letters': jsonEncode([
        {
          'id': 'l1',
          'content': 'x',
          'isFromAi': true,
          'read': false,
          'createdAt': '2026-08-21T10:00:00.000',
        },
      ]),
    });

    final ctx = await buildMemoryContext();

    // 这些句子全都搬进 memoryReadingRules 了，尾部一句都不该有
    for (final fixed in [
      '你住在用户手机上',
      '不用背诵',
      '不要主动罗列',
      '照标签说',
      '只有信例外',
      '不要编',
      '不要假装记得原文',
    ]) {
      expect(
        ctx.contains(fixed),
        isFalse,
        reason: '「$fixed」是固定说明，该在 memoryReadingRules 里，不该每轮重发',
      );
    }

    // 但数据本身要在
    expect(ctx.contains('日记：一共 1 篇'), isTrue);
    expect(ctx.contains('一隅收藏：一共 1 条'), isTrue);
    expect(ctx.contains('信：往来 1 封'), isTrue);
    expect(ctx.contains('还没拆开看'), isTrue);

    // ignore: avoid_print
    print('=====拆分后·尾部：${ctx.length} 字，前缀固定规则：${memoryReadingRules.length} 字=====');
  });
}
