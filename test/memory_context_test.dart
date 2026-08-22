import 'dart:convert';

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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
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
    expect(ctx.contains('recall_records'), isTrue);

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
}
