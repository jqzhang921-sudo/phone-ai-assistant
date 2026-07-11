import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final theme = Theme.of(context);

    // User bubble: slightly darker than surface; AI bubble: surfaceContainerHighest
    final bgColor = isUser
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7)
        : theme.colorScheme.surfaceContainerHighest;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _showCopyMenu(context),
            child: Row(
              mainAxisAlignment:
                  isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUser) _buildAvatar(theme, isUser: false),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.imageData != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                base64Decode(message.imageData!),
                                height: 160,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        if (isUser)
                          Text(
                            message.content,
                            style: TextStyle(
                              color: theme.colorScheme.onSurface,
                            ),
                          )
                        else
                          MarkdownBody(
                            data: message.content,
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(
                                color: theme.colorScheme.onSurface,
                              ),
                              code: TextStyle(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHigh,
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isUser) const SizedBox(width: 8),
                if (isUser) _buildAvatar(theme, isUser: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showCopyMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('复制消息'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.content));
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ 已复制'),
                    duration: Duration(seconds: 1),
                  ),
                );
              },
            ),
            if (message.imageData != null)
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('复制图片'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message.content));
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('✅ 已复制'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, {required bool isUser}) {
    return CircleAvatar(
      radius: 14,
      backgroundColor: isUser
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.primaryContainer,
      child: Icon(
        isUser ? Icons.person : Icons.smart_toy,
        size: 16,
        color: isUser
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.onPrimaryContainer,
      ),
    );
  }
}
