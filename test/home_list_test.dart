import 'package:flutter_test/flutter_test.dart';
import 'package:phone_ai_assistant/models/conversation_summary.dart';
import 'package:phone_ai_assistant/services/home_list.dart';

ConversationSummary _c(String id, {bool pinned = false}) => ConversationSummary(
  id: id,
  title: id,
  createdAt: DateTime(2026, 9, 16),
  updatedAt: DateTime(2026, 9, 16),
  model: 'test',
  isPinned: pinned,
  messageCount: 1,
  hasSystemPrompt: false,
  lines: const [],
);

List<String> _ids(List<ConversationSummary> cs) => [for (final c in cs) c.id];

void main() {
  group('收起时', () {
    test('置顶的全留，再加最近的一条', () {
      // 她现在的样子：钉了两条，后面一串没钉的。
      final all = [
        _c('Mu5e', pinned: true),
        _c('沐', pinned: true),
        _c('最近'),
        _c('更早'),
        _c('再早'),
      ];
      expect(_ids(homeConversations(all, expanded: false)), [
        'Mu5e',
        '沐',
        '最近',
      ]);
    });

    test('一条都没置顶：只留最近那条', () {
      final all = [_c('最近'), _c('更早'), _c('再早')];
      expect(_ids(homeConversations(all, expanded: false)), ['最近']);
    });

    test('全都置顶：一条不藏——那是她一条条钉上去的', () {
      final all = [_c('a', pinned: true), _c('b', pinned: true)];
      expect(_ids(homeConversations(all, expanded: false)), ['a', 'b']);
    });

    test('空列表不出错', () {
      expect(homeConversations([], expanded: false), isEmpty);
    });

    test('只有一条：收起和展开看到的一样', () {
      final all = [_c('唯一')];
      expect(_ids(homeConversations(all, expanded: false)), ['唯一']);
      expect(_ids(homeConversations(all, expanded: true)), ['唯一']);
    });
  });

  group('展开时', () {
    test('全给，但仍受上限约束', () {
      final all = [for (var i = 0; i < 30; i++) _c('c$i')];
      expect(homeConversations(all, expanded: true).length, 20);
      expect(homeConversations(all, expanded: true, max: 5).length, 5);
    });

    test('顺序原样不动', () {
      final all = [_c('b', pinned: true), _c('a'), _c('c')];
      expect(_ids(homeConversations(all, expanded: true)), ['b', 'a', 'c']);
    });
  });
}
