import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/chat_message.dart';
import '../services/tts_service.dart';
import '../config/app_shape.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isAssistant = message.role == MessageRole.assistant;
    final tts = context.watch<TtsService>();
    final theme = Theme.of(context);

    final scheme = theme.colorScheme;
    // 半透明气泡：浅色系，贴近"毛玻璃"质感，聊天背景图可透出
    final bgColor =
        isUser
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
            : scheme.surface.withValues(alpha: 0.75);
    final textColor = isUser ? scheme.onPrimaryContainer : scheme.onSurface;
    final radius =
        isUser
            ? const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(6),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            )
            : const BorderRadius.only(
              topLeft: Radius.circular(6),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () {
              HapticFeedback.mediumImpact();
              _showCopyMenu(context);
            },
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
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: radius,
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.imageData != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.sm),
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
                            style: TextStyle(color: textColor),
                          )
                        else
                          MarkdownBody(
                            data: message.content,
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(color: textColor),
                              code: TextStyle(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHigh,
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
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
          // 时间戳
          Padding(
            padding: EdgeInsets.only(
              left: isUser ? 0 : 36,
              right: isUser ? 36 : 0,
              top: 4,
            ),
            child: Text(
              'time: ${_formatTimestamp(message.timestamp)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
          if (isAssistant && message.content.trim().isNotEmpty)
            _buildSpeakerButton(context, tts, theme),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void _showCopyMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.copy),
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
                    leading: const Icon(PhosphorIconsRegular.image),
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

  Widget _buildSpeakerButton(
    BuildContext context,
    TtsService tts,
    ThemeData theme,
  ) {
    final loading = tts.isLoading(message.id);
    final playing = tts.isPlaying(message.id);
    // 缩进对齐到气泡下方（头像直径 28 + 间距 8）
    return Padding(
      padding: const EdgeInsets.only(left: 36, top: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          try {
            await context.read<TtsService>().toggle(
              message.id,
              message.content,
            );
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('$e')));
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child:
              loading
                  ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  )
                  : Icon(
                    playing
                        ? PhosphorIconsRegular.stopCircle
                        : PhosphorIconsRegular.speakerHigh,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
        ),
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, {required bool isUser}) {
    return CircleAvatar(
      radius: 14,
      backgroundColor:
          isUser
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer,
      child: Icon(
        isUser ? PhosphorIconsRegular.user : PhosphorIconsRegular.robot,
        size: 16,
        color:
            isUser
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.onPrimaryContainer,
      ),
    );
  }
}
