import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/diary_entry.dart';
import '../services/app_providers.dart';
import '../services/diary_generator.dart';
import '../services/storage_service.dart';

class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  final _uuid = const Uuid();
  List<DiaryEntry> _entries = [];
  bool _loading = true;
  bool _generating = false;
  bool _hasToday = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await StorageService.listDiaryEntries();
    final hasToday = await StorageService.hasDiaryEntryForToday();
    if (mounted) {
      setState(() {
        _entries = entries;
        _hasToday = hasToday;
        _loading = false;
      });
    }
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_generating || _hasToday) ? null : _generateToday,
        icon:
            _generating
                ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(PhosphorIconsRegular.pencilSimple),
        label: Text(_hasToday ? '今天已写过' : (_generating ? '写作中…' : '记一篇今天的日记')),
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
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
                itemCount: _entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  return _DiaryCard(
                    entry: entry,
                    onDelete: () async {
                      await StorageService.deleteDiaryEntry(entry.id);
                      await _load();
                    },
                  );
                },
              ),
    );
  }
}

class _DiaryCard extends StatelessWidget {
  final DiaryEntry entry;
  final VoidCallback onDelete;

  const _DiaryCard({required this.entry, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _showDetail(context),
      onLongPress: () => _confirmDelete(context),
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
            Text(
              entry.dateKey,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              entry.summary,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.4,
            maxChildSize: 0.95,
            expand: false,
            builder: (ctx, scrollController) {
              final theme = Theme.of(ctx);
              return Padding(
                padding: const EdgeInsets.all(20),
                child: ListView(
                  controller: scrollController,
                  children: [
                    Text(
                      entry.dateKey,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      entry.content,
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除这篇日记？'),
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
    if (ok == true) onDelete();
  }
}
