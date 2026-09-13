import '../models/chat_message.dart';
import '../models/conversation_summary.dart';

/// A single match within a conversation
///
/// 带的是 [MessageRole] 而不是整条 `ChatMessage`：命中之后只需要知道
/// 「这是他说的还是它说的」来挑图标，而带着整条消息就等于把正文（可能还有
/// base64 图片）钉在搜索结果上。见 [ConversationSummary]。
class MessageMatch {
  final MessageRole? role;
  final int? messageIndex;
  final String snippet;
  final bool isTitleMatch;

  const MessageMatch({
    this.role,
    this.messageIndex,
    required this.snippet,
    this.isTitleMatch = false,
  });
}

/// Result of searching a single conversation
class ConversationSearchResult {
  final ConversationSummary conversation;
  final List<MessageMatch> matches;

  const ConversationSearchResult(this.conversation, this.matches);

  bool get titleMatched => matches.any((m) => m.isTitleMatch);
}

/// Value returned by SearchDelegate when user taps a result
///
/// 选中之后**要按 id 去把完整对话读出来**才能打开——带上来的只是索引。
/// 那一读在 `chat_screen._openConversation` 里。
class HistorySearchSelection {
  final ConversationSummary conversation;
  final int? scrollToMessageIndex;

  const HistorySearchSelection({
    required this.conversation,
    this.scrollToMessageIndex,
  });
}
