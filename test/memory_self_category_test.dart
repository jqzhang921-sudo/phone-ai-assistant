import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/memory_topic.dart';

/// 2026-09-22 加的第五档「关于自己」。
///
/// Cleo：「ai 现在记得都是我的东西……希望他可以慢慢的长出自己」。
/// 前四档全是关于用户的，结构上就没给它留位置。
void main() {
  test('有「关于自己」这一档', () {
    expect(MemoryCategory.values, contains(MemoryCategory.self));
    expect(MemoryCategory.self.label, '关于自己');
  });

  test('每一档都得有标签和给模型的说明', () {
    for (final c in MemoryCategory.values) {
      expect(c.label.trim(), isNotEmpty, reason: c.name);
      expect(c.hint.trim(), isNotEmpty, reason: c.name);
    }
  });

  test('「关于自己」的说明里写明了记经历、不记标签', () {
    // ⚠️ 这条规矩是这一档能不能成立的关键：给自己贴词，它就会去演那个词——
    // 和 rapport 那一档踩的是同一个坑。
    final h = MemoryCategory.self.hint;
    expect(h, contains('做过什么'));
    expect(h, contains('标签'));
  });

  test('老数据照样读得出来——加一档不能影响已存的记忆', () {
    final t = MemoryTopic.fromJson({
      'id': '11111111-2222-3333-4444-555555555555',
      'category': 'profile',
      'name': '怎么称呼',
      'summary': '叫她 Cleo',
      'details': <String>[],
      'source': 'user',
      'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
    });
    expect(t.category, MemoryCategory.profile);
  });

  test('认不出的分类退回「关于 TA」，不抛异常', () {
    final t = MemoryTopic.fromJson({
      'id': '11111111-2222-3333-4444-555555555555',
      'category': '将来某个新类别',
      'name': 'x',
      'summary': 'y',
      'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      'updatedAt': DateTime(2026, 1, 1).toIso8601String(),
    });
    expect(t.category, MemoryCategory.profile);
  });

  test('存进去再读出来，「关于自己」还是「关于自己」', () {
    final t = MemoryTopic(
      id: '11111111-2222-3333-4444-555555555555',
      category: MemoryCategory.self,
      name: '我改过的判断',
      summary: '那条提示挡住了她的输入框',
      details: const ['她因此把整个功能关了'],
      source: MemorySource.ai,
      createdAt: DateTime(2026, 9, 22),
      updatedAt: DateTime(2026, 9, 22),
    );
    expect(MemoryTopic.fromJson(t.toJson()).category, MemoryCategory.self);
  });
}
