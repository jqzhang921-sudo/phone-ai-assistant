import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/services/phone_tools/choice_tool.dart';

/// 2026-09-22 Cleo 要的选项卡：方式多的时候给几个选项，点一个就算答了。
void main() {
  test('正常两个选项', () async {
    final r = await ChoiceTool.execute({
      'question': '这个功能做成哪种',
      'options': [
        {'label': '简单版', 'note': '今天就能用'},
        {'label': '完整版', 'note': '要多花两天'},
      ],
    });
    expect(r['success'], true);
    expect((r['options'] as List).length, 2);
    expect((r['options'] as List).first['note'], '今天就能用');
  });

  test('少于两个不叫选择', () async {
    final r = await ChoiceTool.execute({
      'question': '要不要',
      'options': [
        {'label': '要'},
      ],
    });
    expect(r['success'], false);
  });

  test('超过四个就是菜单，挡住', () async {
    // ⚠️ 选项多到要翻，说明它还没想清楚该问什么。
    final r = await ChoiceTool.execute({
      'question': '选一个',
      'options': [
        for (var i = 0; i < 5; i++) {'label': '选项$i'},
      ],
    });
    expect(r['success'], false);
    expect(r['error'], contains('菜单'));
  });

  test('没有问题、或选项没名字，都挡住', () async {
    expect((await ChoiceTool.execute({'options': []}))['success'], false);
    expect(
      (await ChoiceTool.execute({
        'question': '选',
        'options': [
          {'label': ''},
          {'label': 'b'},
        ],
      }))['success'],
      false,
    );
  });

  test('note 可以不给', () async {
    final r = await ChoiceTool.execute({
      'question': '选一个',
      'options': [
        {'label': 'a'},
        {'label': 'b'},
      ],
    });
    expect(r['success'], true);
    expect((r['options'] as List).first.containsKey('note'), false);
  });

  test('说明里写明了「有明显更好的就别摆选择题」', () {
    // 这是这个工具最容易被滥用的地方：把已经有答案的问题推回给她。
    expect(ChoiceTool.definition.description, contains('偷懒'));
  });
}
