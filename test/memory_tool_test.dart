import 'package:flutter_test/flutter_test.dart';

import 'package:phone_ai_assistant/models/memory_topic.dart';
import 'package:phone_ai_assistant/services/phone_tools/memory_tool.dart';

/// 记忆四个动作合成一个工具之后，分发那一层。
///
/// 合并的代价是：**选错动作不再是「调错工具」，而是「参数填错」**——
/// 前者模型自己看得出来，后者得靠返回值说清楚。所以认不出的 action
/// 必须把四个选项原样列回去，不能只说一句「参数错误」。
void main() {
  group('action 分发', () {
    test('四个动作都在 schema 的 enum 里', () {
      final props =
          MemoryTools.definition.inputSchema['properties']
              as Map<String, dynamic>;
      final action = props['action'] as Map<String, dynamic>;
      expect(
        (action['enum'] as List).toSet(),
        {'open', 'remember', 'update', 'forget'},
      );
      expect(
        MemoryTools.definition.inputSchema['required'],
        ['action'],
      );
    });

    test('工具名是 memory，四个旧名字都不再注册', () {
      expect(MemoryTools.definition.name, 'memory');
    });

    test('认不出的 action 要把选项列回去，不能只说一句参数错误', () async {
      final r = await MemoryTools.execute({'action': 'delete'});
      expect(r['success'], isFalse);
      final err = r['error'] as String;
      for (final a in ['open', 'remember', 'update', 'forget']) {
        expect(err, contains(a), reason: '错误信息里得有 $a');
      }
      // 把它填的那个原样回显，它才知道自己写了什么
      expect(err, contains('delete'));
    });

    test('没给 action 也走同一条路，不抛', () async {
      final r = await MemoryTools.execute({});
      expect(r['success'], isFalse);
      expect(r['error'], contains('remember'));
    });

    test('大小写和空格不该卡住它', () async {
      // 走到 open 的参数校验，说明分发认出来了（编号缺失是下一层的事）
      final r = await MemoryTools.execute({'action': '  OPEN '});
      expect(r['success'], isFalse);
      expect(r['error'], contains('编号'));
    });

    test('分类说明真的进了 schema —— 之前这里的插值被转义写坏过', () {
      final props =
          MemoryTools.definition.inputSchema['properties']
              as Map<String, dynamic>;
      final desc =
          (props['category'] as Map<String, dynamic>)['description'] as String;
      // 不该出现未展开的插值残骸
      expect(desc, isNot(contains(r'$_categoryHelp')));
      // 每个分类的名字都该在里面
      for (final c in MemoryCategory.values) {
        expect(desc, contains(c.name), reason: '缺了分类 ${c.name}');
      }
    });
  });
}
