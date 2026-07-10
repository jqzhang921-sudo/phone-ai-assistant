import 'package:flutter/material.dart';
import '../models/chat_message.dart';

class ToolCallCard extends StatefulWidget {
  final List<ToolCallInfo> toolCalls;

  const ToolCallCard({super.key, required this.toolCalls});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 40),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.secondary.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.build, size: 16, color: theme.colorScheme.secondary),
                    const SizedBox(width: 6),
                    Text(
                      '🛠 ${widget.toolCalls.map((t) => t.name).join(", ")}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: widget.toolCalls.map((tc) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            tc.name,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontFamily: 'monospace',
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tc.arguments.toString(),
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  )).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ToolResultCard extends StatefulWidget {
  final String content;

  const ToolResultCard({super.key, required this.content});

  @override
  State<ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<ToolResultCard> {
  bool _expanded = false;
  Map<String, dynamic>? _resultMap;

  @override
  void initState() {
    super.initState();
    _resultMap = _tryParseMap(widget.content);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final success = _resultMap?['success'] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 40),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.colorScheme.tertiary.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      success ? Icons.check_circle_outline : Icons.info_outline,
                      size: 16,
                      color: success ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      success ? '✅ 工具执行成功' : '📋 工具结果',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded && _resultMap != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _resultMap!.entries
                      .where((e) => e.key != 'data')
                      .map((e) => Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '${e.key}: ${e.value}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _tryParseMap(String content) {
    try {
      final cleaned = content.replaceAll('{', '').replaceAll('}', '');
      final map = <String, dynamic>{};
      for (final pair in cleaned.split(',')) {
        final parts = pair.split(':');
        if (parts.length >= 2) {
          map[parts[0].trim()] = parts.sublist(1).join(':').trim();
        }
      }
      return map.isNotEmpty ? map : null;
    } catch (_) {
      return null;
    }
  }
}
