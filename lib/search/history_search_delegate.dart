import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import 'search_result_model.dart';

class HistorySearchDelegate extends SearchDelegate<HistorySearchSelection?> {
  final List<Conversation> _allConversations;

  HistorySearchDelegate(this._allConversations)
      : super(searchFieldLabel: '搜索历史对话...');

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      if (query.isNotEmpty)
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () => query = '',
        ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () => close(context, null),
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    if (query.isEmpty) return _buildRecentList(context);
    return _buildResultsWidget(context);
  }

  @override
  Widget buildResults(BuildContext context) {
    if (query.isEmpty) return _buildRecentList(context);
    return _buildResultsWidget(context);
  }

  Widget _buildRecentList(BuildContext context) {
    if (_allConversations.isEmpty) {
      return const Center(child: Text('暂无历史对话'));
    }
    return ListView.builder(
      itemCount: _allConversations.length,
      itemBuilder: (ctx, i) {
        final conv = _allConversations[i];
        return ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${conv.messages.length} 条消息 · ${conv.model}',
            style: const TextStyle(fontSize: 12),
          ),
          onTap: () => close(context, HistorySearchSelection(conversation: conv)),
        );
      },
    );
  }

  List<ConversationSearchResult> _search() {
    final lower = query.toLowerCase();
    final results = <ConversationSearchResult>[];

    for (final conv in _allConversations) {
      final matches = <MessageMatch>[];

      // Search title
      if (conv.title.toLowerCase().contains(lower)) {
        matches.add(MessageMatch(
          snippet: conv.title,
          isTitleMatch: true,
        ));
      }

      // Search messages
      for (int i = 0; i < conv.messages.length; i++) {
        final msg = conv.messages[i];
        // Skip internal tool messages
        if (msg.role == MessageRole.toolCall ||
            msg.role == MessageRole.toolResult) {
          continue;
        }
        final contentLower = msg.content.toLowerCase();
        int start = 0;
        while (true) {
          final idx = contentLower.indexOf(lower, start);
          if (idx == -1) break;
          final snippetStart = (idx - 30).clamp(0, msg.content.length);
          final snippetEnd =
              (idx + query.length + 30).clamp(0, msg.content.length);
          matches.add(MessageMatch(
            message: msg,
            messageIndex: i,
            snippet: msg.content.substring(snippetStart, snippetEnd),
          ));
          start = idx + 1;
          if (matches.length >= 10) break; // cap per conversation
        }
        if (matches.length >= 10) break;
      }

      if (matches.isNotEmpty) {
        results.add(ConversationSearchResult(conv, matches));
      }
    }

    results.sort(
        (a, b) => b.conversation.updatedAt.compareTo(a.conversation.updatedAt));
    return results;
  }

  Widget _buildResultsWidget(BuildContext context) {
    final results = _search();
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('未找到匹配的对话',
                style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (ctx, i) => _buildResultCard(context, results[i]),
    );
  }

  Widget _buildResultCard(BuildContext context, ConversationSearchResult result) {
    final theme = Theme.of(context);
    final displayMatches = result.matches.take(3).toList();
    final hasMore = result.matches.length > 3;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => close(
          context,
          HistorySearchSelection(conversation: result.conversation),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header: title + match count
              Row(
                children: [
                  Expanded(
                    child: Text(
                      result.conversation.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${result.matches.length}条匹配',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 16),
              // Message snippets
              ...displayMatches.map((m) => _buildSnippet(context, m, result.conversation)),
              if (hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '... 还有 ${result.matches.length - 3} 条匹配',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSnippet(BuildContext context, MessageMatch match, Conversation conversation) {
    final theme = Theme.of(context);
    final icon = match.isTitleMatch
        ? Icons.title
        : match.message?.role == MessageRole.user
            ? Icons.person
            : Icons.smart_toy;

    return InkWell(
      onTap: match.isTitleMatch
          ? null
          : () => close(
                context,
                HistorySearchSelection(
                  conversation: conversation,
                  scrollToMessageIndex: match.messageIndex,
                ),
              ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14,
                color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: _buildHighlightedText(context, match.snippet),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHighlightedText(BuildContext context, String text) {
    final theme = Theme.of(context);
    final lower = text.toLowerCase();
    final queryLower = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final idx = lower.indexOf(queryLower, start);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + query.length),
        style: TextStyle(
          backgroundColor: Colors.amber.withAlpha(80),
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ));
      start = idx + query.length;
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurface,
        ),
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}
