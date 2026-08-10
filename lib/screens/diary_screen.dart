import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/diary_entry.dart';
import '../services/app_providers.dart';
import '../services/diary_generator.dart';
import '../services/storage_service.dart';

/// 同一天的所有日记聚成一组，列表里显示为一张卡。
class _DayGroup {
  final String dateKey;

  /// 按写入时间升序，最早的在最前。
  final List<DiaryEntry> entries;

  _DayGroup(this.dateKey, this.entries);

  /// 折叠卡片上显示这一天最早的一条（"这一天是从……开始的"）。
  DiaryEntry get earliest => entries.first;
}

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final _uuid = const Uuid();
  List<_DayGroup> _groups = [];
  bool _loading = true;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await StorageService.listDiaryEntries();
    if (mounted) {
      setState(() {
        _groups = _groupByDay(entries);
        _loading = false;
      });
    }
  }

  List<_DayGroup> _groupByDay(List<DiaryEntry> entries) {
    final byDay = <String, List<DiaryEntry>>{};
    for (final e in entries) {
      byDay.putIfAbsent(e.dateKey, () => []).add(e);
    }
    final groups =
        byDay.entries.map((kv) {
          final list = [...kv.value]
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          return _DayGroup(kv.key, list);
        }).toList();
    // dateKey 是零填充的 YYYY-MM-DD，字符串倒序即日期倒序
    groups.sort((a, b) => b.dateKey.compareTo(a.dateKey));
    return groups;
  }

  Future<void> _generateToday() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) {
      _toast('还没配置AI，去设置里配一下吧');
      return;
    }
    setState(() => _generating = true);
    try {
      final content = await generateTodayDiary(aiClient: aiClient);
      if (content == null) {
        _toast('今天还没有聊天记录，先去聊会儿天吧');
        return;
      }
      final entry = DiaryEntry(
        id: _uuid.v4(),
        date: DateTime.now(),
        content: content,
      );
      await StorageService.addDiaryEntry(entry);
      await _load();
    } catch (e) {
      _toast('生成失败：$e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('日记')),
      // AI 记的是"某一刻"，这个按钮写的是"这一天"，两者不冲突，
      // 所以不再因为今天已有日记就禁用。
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating ? null : _generateToday,
        icon:
            _generating
                ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(PhosphorIconsRegular.pencilSimple),
        label: Text(_generating ? '写作中…' : '记一篇今天的日记'),
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _groups.isEmpty
              ? Center(
                child: Text(
                  '还没有日记\n聊完天后点右下角写一篇吧',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
              : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _groups.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  return _DayCard(group: _groups[index], onChanged: _load);
                },
              ),
    );
  }
}

class _DayCard extends StatelessWidget {
  final _DayGroup group;
  final Future<void> Function() onChanged;

  const _DayCard({required this.group, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = group.entries.length;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openDay(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  group.dateKey,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (count > 1)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count 则',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              group.earliest.summary,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openDay(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DayDetailSheet(group: group),
    );
    await onChanged();
  }
}

class _DayDetailSheet extends StatefulWidget {
  final _DayGroup group;

  const _DayDetailSheet({required this.group});

  @override
  State<_DayDetailSheet> createState() => _DayDetailSheetState();
}

class _DayDetailSheetState extends State<_DayDetailSheet> {
  late List<DiaryEntry> _entries;

  @override
  void initState() {
    super.initState();
    _entries = [...widget.group.entries];
  }

  String _timeOf(DiaryEntry entry) {
    final t = entry.createdAt;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _delete(DiaryEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除这一则？'),
            content: Text(
              '${_timeOf(entry)} 写的这一则会被删掉，这一天的其他日记不受影响。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await StorageService.deleteDiaryEntry(entry.id);
    if (!mounted) return;
    setState(() => _entries.removeWhere((e) => e.id == entry.id));
    // 这一天被删空了，就没必要停留在详情页
    if (_entries.isEmpty && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        final theme = Theme.of(ctx);
        final scheme = theme.colorScheme;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: ListView(
            controller: scrollController,
            children: [
              Row(
                children: [
                  Text(
                    widget.group.dateKey,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_entries.length > 1)
                    Text(
                      '${_entries.length} 则',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              for (final entry in _entries)
                Container(
                  margin: const EdgeInsets.only(bottom: 18),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.35),
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _timeOf(entry),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () => _delete(entry),
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                PhosphorIconsRegular.trash,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.content,
                        style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
