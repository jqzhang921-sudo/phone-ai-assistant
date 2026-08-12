import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/chat_message.dart';
import '../config/app_shape.dart';

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
        // 工具调用是元信息，不是内容：不描边、不用主题色染色，
        // 只用一层极淡的中性底把它和消息区分开。
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.wrench,
                      size: 16,
                      color: theme.colorScheme.secondary,
                    ),
                    const SizedBox(width: 6),
                    // 图标已经表达「这是工具」，不再叠一个 emoji
                    Text(
                      widget.toolCalls.map((t) => t.name).join('、'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded
                          ? PhosphorIconsRegular.caretUp
                          : PhosphorIconsRegular.caretDown,
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
                  children:
                      widget.toolCalls
                          .map(
                            (tc) => Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          theme.colorScheme.tertiaryContainer,
                                      borderRadius: BorderRadius.circular(AppRadius.sm),
                                    ),
                                    child: Text(
                                      tc.name,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            fontFamily: 'monospace',
                                            color:
                                                theme
                                                    .colorScheme
                                                    .onTertiaryContainer,
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
                            ),
                          )
                          .toList(),
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
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.35,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    // 成功是常态，不值得用绿色去强调；只有失败才需要抢注意力。
                    // 之前用的是写死的 Colors.green / Colors.orange，绕开了
                    // ColorScheme，在暖色背景上会显得很跳。
                    Icon(
                      success
                          ? PhosphorIconsRegular.checkCircle
                          : PhosphorIconsRegular.warningCircle,
                      size: 16,
                      color:
                          success
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      success ? '完成' : '未成功',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color:
                            success
                                ? theme.colorScheme.onSurfaceVariant
                                : theme.colorScheme.error,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      _expanded
                          ? PhosphorIconsRegular.caretUp
                          : PhosphorIconsRegular.caretDown,
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
                  children:
                      _resultMap!.entries
                          .where((e) => e.key != 'data')
                          .map(
                            (e) => Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${e.key}: ${e.value}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          )
                          .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 工具结果是 jsonEncode 出来的真 JSON，直接解析。
  ///
  /// 这里原来是手写的「去掉花括号按逗号切」，结果键会带上引号（`"success"`）、
  /// 值全变成字符串（`'true'`），于是 `_resultMap['success'] == true` 恒为
  /// false——每一次调用都被判成失败。值里只要含逗号或冒号也会被切坏。
  Map<String, dynamic>? _tryParseMap(String content) {
    try {
      final decoded = jsonDecode(content);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}
