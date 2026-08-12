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
        // 无底色、无边框，同结果卡
        decoration: const BoxDecoration(),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
      padding: const EdgeInsets.only(bottom: 6, left: 40),
      child: Align(
        // 只占实际需要的宽度：工具结果是元信息，不该像消息一样铺满整行
        alignment: Alignment.centerLeft,
        child: Container(
          // 无底色、无边框：工具调用是元信息，一行灰字加箭头就够，
          // 给它一个带背景的卡片会让它和真正的消息抢注意力。
          decoration: const BoxDecoration(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                      const SizedBox(width: 5),
                      Text(
                        success ? '完成' : '未成功',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color:
                              success
                                  ? theme.colorScheme.onSurfaceVariant
                                  : theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        _expanded
                            ? PhosphorIconsRegular.caretUp
                            : PhosphorIconsRegular.caretDown,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded && _resultMap != null)
                ConstrainedBox(
                  // 高度封顶 + 自己滚。
                  //
                  // 一次网页搜索能吐出几千字符（5 条结果，每条正文截到 600 字），
                  // 原来整段直接铺在聊天流里，把整屏顶满；看完想收起，还得往回
                  // 滚很远才够得到上面那个「完成」。封到 260 之后，展开区自己滚，
                  // 头部始终在手边。
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in _resultMap!.entries.where(
                          (e) => e.key != 'data',
                        ))
                          if (e.key == 'results' && e.value is List)
                            _buildResultList(theme, e.value as List)
                          else
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '${e.key}: ${_clip(e.value.toString(), 200)}',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 搜索类工具的 results 是一整个列表，`toString()` 出来是几千字符的 Dart
  /// Map 原文（`[{title: …, url: …, content: …}]`），键值没引号、正文里的换行
  /// 全铺开，基本没法读。这里拆成「标题 + 一句摘要」，想看全文点原始链接。
  Widget _buildResultList(ThemeData theme, List<dynamic> results) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in results)
          if (r is Map)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _clip((r['title'] ?? '(无标题)').toString(), 60),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((r['content'] ?? '').toString().trim().isNotEmpty)
                    Text(
                      _clip(r['content'].toString(), 140),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
      ],
    );
  }

  /// 压成一行再截断：抓回来的正文里全是换行和连续空格，原样显示会把
  /// 一条结果拉成十几行。
  static String _clip(String s, int max) {
    final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
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
