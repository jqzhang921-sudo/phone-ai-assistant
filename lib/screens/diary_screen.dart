import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/diary_entry.dart';
import '../services/app_providers.dart';
import '../services/diary_generator.dart';
import '../services/storage_service.dart';
import '../config/app_shape.dart';

/// 同一天的所有日记聚成一组，列表里显示为一张卡。
class _DayGroup {
  final String dateKey;

  /// 按写入时间升序，最早的在最前。
  final List<DiaryEntry> entries;

  _DayGroup(this.dateKey, this.entries);
}

/// 列表里实际渲染的一项：一整天 + 当前搜索命中的那几则。
/// 没有搜索时 [matched] 就是这一天的全部。
class _DayHit {
  final _DayGroup day;
  final List<DiaryEntry> matched;

  _DayHit(this.day, this.matched);

  /// 折叠卡上显示命中里最早的一条（没搜索时即当天最早的一条）。
  DiaryEntry get preview => matched.first;

  bool get isPartial => matched.length != day.entries.length;
}

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final _uuid = const Uuid();
  final _searchController = TextEditingController();

  List<_DayGroup> _groups = [];
  bool _loading = true;
  bool _generating = false;
  bool _searching = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  /// 日记全部在内存里（一个 SharedPreferences 字符串），直接过滤即可，不需要索引。
  List<_DayHit> get _hits {
    if (_query.isEmpty) {
      return _groups.map((g) => _DayHit(g, g.entries)).toList();
    }
    final q = _query.toLowerCase();
    final hits = <_DayHit>[];
    for (final g in _groups) {
      final matched =
          g.entries.where((e) => e.content.toLowerCase().contains(q)).toList();
      if (matched.isNotEmpty) hits.add(_DayHit(g, matched));
    }
    return hits;
  }

  void _toggleSearch() {
    setState(() {
      if (_searching) {
        _searching = false;
        _query = '';
        _searchController.clear();
      } else {
        _searching = true;
      }
    });
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
    final hits = _hits;
    return Scaffold(
      appBar: AppBar(
        title:
            _searching
                ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '搜日记内容…',
                    border: InputBorder.none,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                )
                : const Text('日记'),
        actions: [
          IconButton(
            tooltip: _searching ? '退出搜索' : '搜索',
            icon: Icon(
              _searching
                  ? PhosphorIconsRegular.x
                  : PhosphorIconsRegular.magnifyingGlass,
            ),
            onPressed: _toggleSearch,
          ),
        ],
      ),
      // AI 记的是"某一刻"，这个按钮写的是"这一天"，两者不冲突，
      // 所以不因为今天已有日记就禁用。
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
              : hits.isEmpty
              ? Center(
                child: Text(
                  _query.isEmpty
                      ? '还没有日记\n聊完天后点右下角写一篇吧'
                      : '没有包含「$_query」的日记',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
              : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: hits.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  return _DayCard(
                    hit: hits[index],
                    query: _query,
                    onChanged: _load,
                  );
                },
              ),
    );
  }
}

class _DayCard extends StatelessWidget {
  final _DayHit hit;
  final String query;
  final Future<void> Function() onChanged;

  const _DayCard({
    required this.hit,
    required this.query,
    required this.onChanged,
  });

  /// 搜索时把预览挪到命中位置附近，好让人一眼看出为什么匹配。
  String _previewText() {
    final content = hit.preview.content;
    if (query.isEmpty) return hit.preview.summary;

    final idx = content.toLowerCase().indexOf(query.toLowerCase());
    if (idx < 0) return hit.preview.summary;

    var start = idx - 20;
    if (start < 0) start = 0;
    var end = idx + query.length + 40;
    if (end > content.length) end = content.length;

    final head = start > 0 ? '…' : '';
    final tail = end < content.length ? '…' : '';
    return '$head${content.substring(start, end)}$tail';
  }

  String _countLabel() {
    if (hit.isPartial) return '${hit.matched.length}/${hit.day.entries.length} 则';
    return '${hit.matched.length} 则';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showCount = hit.isPartial || hit.matched.length > 1;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => _openDay(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.12)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  hit.day.dateKey,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (showCount)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      _countLabel(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _previewText(),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// 点开始终展示这一天的全部，搜索命中只影响列表上的预览。
  Future<void> _openDay(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _DayDetailSheet(group: hit.day),
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
            content: Text('${_timeOf(entry)} 写的这一则会被删掉，这一天的其他日记不受影响。'),
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
                            borderRadius: BorderRadius.circular(AppRadius.md),
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
