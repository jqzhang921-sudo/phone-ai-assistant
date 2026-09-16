import '../models/conversation_summary.dart';

/// 主页「最近对话」平时露几条。
///
/// 2026-09-16 Cleo：「如果主页只显示一个对话框，其他的隐藏起来怎么样」。
/// 主页原来是一摞会话卡片，那个形状读起来就是聊天软件的列表，和 Nook
/// 「一个角落」的设定打架。收起之后，主页从「你有 N 场对话」变成「你和它在这儿」。
///
/// ## 收起时留哪些
///
/// **置顶的全留，再加最近聊过的那一条。** 置顶是她明确钉上去的常驻摊子
/// （现在是两条），把它们也藏起来等于否定那个动作；而最近那条回答的是
/// 「你现在在哪儿」。
///
/// 置顶多了会把这一屏重新填满——但那是她自己一条条钉的，不该由这里替她封顶。
///
/// 顺序沿用传进来的顺序（存储那边已经排好，置顶在前）。
List<ConversationSummary> homeConversations(
  List<ConversationSummary> all, {
  required bool expanded,
  int max = 20,
}) {
  if (expanded) return all.take(max).toList();
  final shown = <ConversationSummary>[];
  var tookRecent = false;
  for (final c in all) {
    if (c.isPinned) {
      shown.add(c);
    } else if (!tookRecent) {
      // 没置顶的里面，第一条就是最近的那条。
      shown.add(c);
      tookRecent = true;
    }
  }
  return shown;
}
