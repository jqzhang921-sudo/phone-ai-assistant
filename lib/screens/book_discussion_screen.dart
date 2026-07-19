import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/discussion_note.dart';
import '../services/discussion_generator.dart';
import 'chat_screen.dart';

class BookDiscussionScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;
  final String? bookAuthor;

  const BookDiscussionScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    this.bookAuthor,
  });

  @override
  State<BookDiscussionScreen> createState() => _BookDiscussionScreenState();
}

class _BookDiscussionScreenState extends State<BookDiscussionScreen> {
  final _uuid = const Uuid();
  List<DiscussionNote> _notes = [];
  bool _loaded = false;
  bool _generating = false;

  String get _storageKey => 'discussions_${widget.bookId}';

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      setState(() {
        _notes = list
            .map((j) => DiscussionNote.fromJson(j as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });
    }
    setState(() => _loaded = true);
  }

  Future<void> _saveNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _storageKey, jsonEncode(_notes.map((n) => n.toJson()).toList()));
  }

  Future<void> _generateDiscussion() async {
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
      final content = await generateDiscussionForBook(
        bookId: widget.bookId,
        bookTitle: widget.bookTitle,
        aiClient: aiClient,
      );

      if (content != null) {
        final note = DiscussionNote(
          id: _uuid.v4(),
          bookId: widget.bookId,
          content: content,
        );
        setState(() => _notes.insert(0, note));
        await _saveNotes();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('还没有对话记录，先去聊聊这本书吧')),
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

  Future<void> _createBlankNote() async {
    final note = DiscussionNote(
      id: _uuid.v4(),
      bookId: widget.bookId,
      content: '',
    );
    setState(() => _notes.insert(0, note));
    await _saveNotes();
    // Automatically open the editor for the new note
    _editNote(note);
  }

  Future<void> _editNote(DiscussionNote note) async {
    final controller = TextEditingController(text: note.content);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑笔记'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 12,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '记录你的想法、摘抄喜欢的句子...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != null && mounted) {
      final updated = DiscussionNote(
        id: note.id,
        bookId: note.bookId,
        content: result,
        createdAt: note.createdAt,
      );
      setState(() {
        final index = _notes.indexWhere((n) => n.id == note.id);
        if (index >= 0) _notes[index] = updated;
      });
      await _saveNotes();
    }
  }

  Future<void> _deleteNote(DiscussionNote note) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记'),
        content: const Text('确定要删除这条笔记吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      setState(() => _notes.removeWhere((n) => n.id == note.id));
      await _saveNotes();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('讨论笔记 · 《${widget.bookTitle}》'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建笔记',
            onPressed: _createBlankNote,
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? _emptyState(theme)
              : _buildList(theme),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _generating ? null : _generateDiscussion,
        icon: _generating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.auto_awesome),
        label: Text(_generating ? '生成中...' : '生成 Discussion'),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 64,
                color: theme.colorScheme.primary.withAlpha(80)),
            const SizedBox(height: 12),
            Text('还没有 Discussion 笔记',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('点右下角 AI 生成，或右上角 + 手动写',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _buildList(ThemeData theme) => ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _notes.length,
        itemBuilder: (ctx, i) => _noteCard(theme, _notes[i]),
      );

  Widget _noteCard(ThemeData theme, DiscussionNote note) {
    final dateStr =
        '${note.createdAt.month}/${note.createdAt.day} ${note.createdAt.hour}:${note.createdAt.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: Icon(Icons.auto_awesome,
            size: 20, color: theme.colorScheme.primary),
        title: Text(
          dateStr,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        subtitle: Text(
          note.summary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              note.content,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                onPressed: () => _editNote(note),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, size: 20,
                    color: theme.colorScheme.error),
                tooltip: '删除',
                onPressed: () => _deleteNote(note),
              ),
              const SizedBox(width: 8),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
