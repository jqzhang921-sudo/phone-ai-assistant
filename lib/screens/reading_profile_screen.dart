import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/reading_profile.dart';
import '../services/reading_profile_generator.dart';
import 'chat_screen.dart'; // AiClientProvider

class ReadingProfileScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;
  final String? bookAuthor;

  const ReadingProfileScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    this.bookAuthor,
  });

  @override
  State<ReadingProfileScreen> createState() => _ReadingProfileScreenState();
}

class _ReadingProfileScreenState extends State<ReadingProfileScreen> {
  ReadingProfile? _profile;
  bool _loaded = false;
  bool _generating = false;

  String get _storageKey => 'reading_profile_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      setState(() {
        _profile =
            ReadingProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      });
    }
    setState(() => _loaded = true);
  }

  Future<void> _saveProfile(ReadingProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(profile.toJson()));
  }

  Future<void> _generate() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在设置中配置 API Key')),
        );
      }
      return;
    }

    setState(() => _generating = true);

    try {
      final profile = await generateReadingProfile(
        bookId: widget.bookId,
        bookTitle: widget.bookTitle,
        aiClient: aiClient,
      );

      if (profile != null) {
        setState(() => _profile = profile);
        await _saveProfile(profile);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('还没有讨论记录，先去聊聊这本书吧')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('生成失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _confirmRegenerate() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成'),
        content: const Text('重新生成会覆盖当前的阅读档案，确定吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) _generate();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('阅读档案 · 《${widget.bookTitle}》'),
        actions: [
          if (_profile != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新生成',
              onPressed: _generating ? null : _confirmRegenerate,
            ),
        ],
      ),
      body: _buildBody(theme),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating
            ? null
            : (_profile == null ? _generate : _confirmRegenerate),
        icon: _generating
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.auto_awesome),
        label: Text(_generating
            ? '生成中...'
            : (_profile == null ? '生成阅读档案' : '重新生成')),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_generating) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('AI 正在分析讨论记录...', style: theme.textTheme.bodyLarge),
          ],
        ),
      );
    }

    if (_profile == null || _profile!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories, size: 64,
                color: theme.colorScheme.primary.withValues(alpha: 0.3)),
            const SizedBox(height: 12),
            Text('还没有阅读档案', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('点右下角按钮生成', style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }

    final profile = _profile!;
    final dateStr =
        '${profile.generatedAt.month}/${profile.generatedAt.day} '
        '${profile.generatedAt.hour}:${profile.generatedAt.minute.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sectionCard(
          theme,
          icon: Icons.lightbulb_outline,
          title: '核心观点',
          color: Colors.deepPurple,
          children: profile.coreOpinions.isEmpty
              ? [const Text('暂无', style: TextStyle(color: Colors.grey))]
              : profile.coreOpinions
                  .map((o) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $o', style: theme.textTheme.bodyMedium),
                      ))
                  .toList(),
        ),
        const SizedBox(height: 12),
        _sectionCard(
          theme,
          icon: Icons.help_outline,
          title: '未解问题',
          color: Colors.deepOrange,
          children: profile.unresolvedQuestions.isEmpty
              ? [const Text('暂无疑问 ✨', style: TextStyle(color: Colors.grey))]
              : profile.unresolvedQuestions
                  .map((q) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $q', style: theme.textTheme.bodyMedium),
                      ))
                  .toList(),
        ),
        const SizedBox(height: 12),
        _sectionCard(
          theme,
          icon: Icons.menu_book_outlined,
          title: '整体印象',
          color: theme.colorScheme.primary,
          children: [
            Text(
              profile.discussionSummary,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.7),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            '生成于 $dateStr',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _sectionCard(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required Color color,
    required List<Widget> children,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall?.copyWith(color: color)),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}
