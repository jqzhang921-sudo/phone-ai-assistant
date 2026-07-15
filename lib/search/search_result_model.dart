import '../models/chat_message.dart';
import '../models/conversation.dart';

/// A single match within a conversation
class MessageMatch {
  final ChatMessage? message;
  final int? messageIndex;
  final String snippet;
  final bool isTitleMatch;

  const MessageMatch({
    this.message,
    this.messageIndex,
    required this.snippet,
    this.isTitleMatch = false,
  });
}

/// Result of searching a single conversation
class ConversationSearchResult {
  final Conversation conversation;
  final List<MessageMatch> matches;

  const ConversationSearchResult(this.conversation, this.matches);

  bool get titleMatched => matches.any((m) => m.isTitleMatch);
}

/// Value returned by SearchDelegate when user taps a result
class HistorySearchSelection {
  final Conversation conversation;
  final int? scrollToMessageIndex;

  const HistorySearchSelection({
    required this.conversation,
    this.scrollToMessageIndex,
  });
}
