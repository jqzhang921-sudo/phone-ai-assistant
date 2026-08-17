import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/chat_message.dart';
import '../config/app_shape.dart';

/// 一次工具调用连同它的结果。
class _ToolEntry {
  final String id;
  final String name;
  final Map<String, dynamic> args;

  /// 结果还没回来时是 null（流式过程中会短暂出现）
  Map<String, dynamic>? result;
  String? rawResult;

  _ToolEntry({required this.id, required this.name, required this.args});

  bool get pending => rawResult == null;
  bool get ok => result?['success'] == true;
}

/// 一段连续的工具调用，折叠成一行。
///
/// 原来「调用」和「结果」是两张独立的卡片，各占一行。模型连着调三轮，界面上就是
/// 六行「🔧 web_search / ✓ 完成」交替，把真正的回复挤到屏幕外面去。工具调用是
/// 过程信息，不该比结论还占地方。
///
/// 现在整段折成一行：`🔧 web_search · 3 次 ⌄`，点开才看参数和结果。
class ToolRunCard extends StatefulWidget {
  /// 连续的工具相关消息：assistant(tool_calls) 和 toolResult 混在一起，按原顺序
  final List<ChatMessage> messages;

  const ToolRunCard({super.key, required this.messages});

  @override
  State<ToolRunCard> createState() => _ToolRunCardState();
}

class _ToolRunCardState extends State<ToolRunCard> {
  bool _expanded = false;

  /// 按 tool_call_id 把调用和结果配对。
  List<_ToolEntry> get _entries {
    final entries = <_ToolEntry>[];
    final byId = <String, _ToolEntry>{};

    for (final m in widget.messages) {
      if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        for (final tc in m.toolCalls!) {
          final e = _ToolEntry(id: tc.id, name: tc.name, args: tc.arguments);
          entries.add(e);
          if (tc.id.isNotEmpty) byId[tc.id] = e;
        }
      } else if (m.role == MessageRole.toolResult) {
        final e = byId[m.toolCallId ?? ''];
        // 配不上 id 就挂到最近一个还没结果的调用上，别把结果丢了
        final target = e ?? entries.reversed.where((x) => x.pending).firstOrNull;
        if (target != null) {
          target.rawResult = m.content;
          target.result = _tryParseMap(m.content);
        }
      }
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = _entries;
    if (entries.isEmpty) return const SizedBox.shrink();

    final names = <String>{for (final e in entries) e.name}.join('、');
    final failed = entries.where((e) => !e.pending && !e.ok).length;
    final pending = entries.where((e) => e.pending).length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 40),
      child: Align(
        alignment: Alignment.centerLeft,
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
                    if (pending > 0)
                      SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Icon(
                        PhosphorIconsRegular.wrench,
                        size: 15,
                        // 成功是常态，不值得强调；只有失败才需要抢注意力
                        color: failed > 0 ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        _summary(names, entries.length, failed, pending),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: failed > 0
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Icon(
                      _expanded
                          ? PhosphorIconsRegular.caretUp
                          : PhosphorIconsRegular.caretDown,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                // 高度封顶 + 自己滚。一次网页搜索能吐出几千字符，整段铺开会把
                // 屏幕顶满，看完想收起还得往回滚很远才够得到上面那一行。
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in entries) _entryView(theme, e),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 折叠时那一行文字。一次调用就直接写工具名，多次才带计数。
  String _summary(String names, int total, int failed, int pending) {
    final buf = StringBuffer(names);
    if (total > 1) buf.write(' · $total 次');
    if (pending > 0) {
      buf.write(' · 进行中');
    } else if (failed > 0) {
      buf.write(' · $failed 个未成功');
    }
    return buf.toString();
  }

  Widget _entryView(ThemeData theme, _ToolEntry e) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  e.name,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _clip(_argsText(e.args), 120),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (e.pending)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Text(
                '等结果…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: _resultView(theme, e),
            ),
        ],
      ),
    );
  }

  Widget _resultView(ThemeData theme, _ToolEntry e) {
    final scheme = theme.colorScheme;
    final map = e.result;
    if (map == null) {
      return Text(
        _clip(e.rawResult ?? '', 200),
        style: theme.textTheme.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in map.entries.where((x) => x.key != 'data'))
          if (entry.key == 'results' && entry.value is List)
            _buildResultList(theme, entry.value as List)
          else if (entry.key == 'news' && entry.value is List)
            _buildResultList(theme, entry.value as List)
          else
            Text(
              '${entry.key}: ${_clip(entry.value.toString(), 200)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: entry.key == 'error' ? scheme.error : null,
              ),
            ),
      ],
    );
  }

  /// 搜索类结果的 results / news 是一整个列表，`toString()` 出来是几千字符的
  /// Dart Map 原文（键值没引号、抓回来的正文换行全铺开），基本没法读。
  /// 这里拆成「标题 + 一句摘要」。
  Widget _buildResultList(ThemeData theme, List<dynamic> results) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in results)
          if (r is Map)
            Padding(
              padding: const EdgeInsets.only(top: 5),
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

  String _argsText(Map<String, dynamic> args) {
    if (args.isEmpty) return '(无参数)';
    return args.entries.map((e) => '${e.key}: ${e.value}').join('，');
  }
}

/// 工具结果是 jsonEncode 出来的真 JSON，直接解析。
///
/// 这里原来是手写的「去掉花括号按逗号切」，结果键会带上引号（`"success"`）、
/// 值全变成字符串（`'true'`），于是 `_resultMap['success'] == true` 恒为
/// false——每一次调用都被判成失败。
Map<String, dynamic>? _tryParseMap(String content) {
  try {
    final decoded = jsonDecode(content);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// 压成一行再截断：抓回来的正文里全是换行和连续空格，原样显示会把一条结果
/// 拉成十几行。
String _clip(String s, int max) {
  final oneLine = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length > max ? '${oneLine.substring(0, max)}…' : oneLine;
}
