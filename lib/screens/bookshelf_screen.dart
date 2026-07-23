import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/book.dart';
import '../services/discussion_group_service.dart';
import '../services/weread_service.dart';
import 'book_chat_screen.dart';
import 'book_discussion_screen.dart';
import 'multi_book_chat_screen.dart';
import 'reading_profile_screen.dart';

class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  final _uuid = const Uuid();
  final _picker = ImagePicker();
  List<Book> _books = [];
  bool _loaded = false;
  ReadingStatus? _filterStatus; // null = show all

  static const _storageKey = 'bookshelf_books';

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<Directory> get _coverDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/book_covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _loadBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        setState(() {
          _books = list
              .map((j) => Book.fromJson(j as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        });
      } catch (_) {
        // data format changed — reset
        setState(() => _books = []);
      }
    }
    setState(() => _loaded = true);
  }

  Future<void> _saveBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _books.map((b) => b.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(list));
  }

  Future<void> _importFromWeread() async {
    // Check/save key
    var key = await WereadService.getKey();
    if (key == null || key.isEmpty) {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('微信读书 API Key'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              hintText: 'wrk-...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      );
      if (ok != true) return;
      key = ctrl.text.trim();
      if (key.isEmpty) return;
      await WereadService.saveKey(key);
    }

    try {
      final imported = await WereadService.fetchBooks();
      if (!mounted) return;

      // Skip duplicates
      final existingIds = _books.map((b) => b.title).toSet();
      final newBooks = imported.where((b) => !existingIds.contains(b.title)).toList();

      if (newBooks.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('没有新书，书架已是最新')),
          );
        }
        return;
      }

      setState(() => _books.addAll(newBooks));
      await _saveBooks();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入了 ${newBooks.length} 本书')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  // ── Add ──────────────────────────────────────────────
  Future<void> _addBook() async {
    final titleCtrl = TextEditingController();
    final authorCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加新书'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '书名 *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: authorCtrl,
              decoration: const InputDecoration(
                hintText: '作者',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
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

    if (result != true || !mounted) return;
    final title = titleCtrl.text.trim();
    if (title.isEmpty) return;

    // pick cover?
    String? coverPath;
    final wantCover = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加封面图片？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('选择图片'),
          ),
        ],
      ),
    );
    if (wantCover == true) {
      try {
        final XFile? image =
            await _picker.pickImage(source: ImageSource.gallery, maxWidth: 600);
        if (image != null) {
          final coverDir = await _coverDir;
          final ext = image.path.split('.').last;
          final fileName = '${_uuid.v4()}.$ext';
          final dest = File('${coverDir.path}/$fileName');
          await dest.writeAsBytes(await image.readAsBytes());
          coverPath = dest.path;
        }
      } catch (_) {}
    }

    final book = Book(
      id: _uuid.v4(),
      title: title,
      author: authorCtrl.text.trim().isEmpty ? null : authorCtrl.text.trim(),
      coverPath: coverPath,
    );
    setState(() => _books.insert(0, book));
    await _saveBooks();
  }

  void _showDiscussingDialog() {
    final selected = <String>{};
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(60),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('选择要讨论的书',
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _books.length,
                  itemBuilder: (_, i) {
                    final book = _books[i];
                    final isSel = selected.contains(book.id);
                    return CheckboxListTile(
                      title: Text('《${book.title}》'),
                      subtitle: book.author != null ? Text(book.author!) : null,
                      value: isSel,
                      onChanged: (v) {
                        setSheet(() {
                          if (v == true) {
                            selected.add(book.id);
                          } else {
                            selected.remove(book.id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () async {
                            Navigator.of(ctx).pop();
                            final books = _books
                                .where((b) => selected.contains(b.id))
                                .toList();
                            final bookIds = books.map((b) => b.id).toList();

                            // Check for exact match first
                            final exact =
                                await DiscussionGroupService.findExactMatch(
                                    bookIds);
                            if (exact != null) {
                              // Directly enter existing group
                              if (!mounted) return;
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MultiBookChatScreen(
                                    books: books,
                                    groupId: exact.id,
                                  ),
                                ),
                              );
                              return;
                            }

                            // Check for partial overlap
                            final overlapping =
                                await DiscussionGroupService
                                    .findGroupsContaining(bookIds);
                            String? groupId;

                            // Load last-message previews for each group
                            final previews = <String, String?>{};
                            for (final g in overlapping) {
                              previews[g.id] = await DiscussionGroupService
                                  .lastMessagePreview(g.id);
                            }

                            if (overlapping.isNotEmpty && mounted) {
                              groupId = await _showGroupPicker(
                                  context, overlapping, books, previews);
                              if (groupId == null) return; // cancelled
                            }

                            // No overlap or chose "new" → create group
                            if (groupId == null || groupId == 'new') {
                              final defaultName = books
                                  .map((b) => '《${b.title}》')
                                  .join(' · ');
                              final group =
                                  await DiscussionGroupService.saveGroup(
                                name: defaultName,
                                bookIds: bookIds,
                              );
                              groupId = group.id;
                            }

                            if (!mounted) return;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => MultiBookChatScreen(
                                  books: books,
                                  groupId: groupId,
                                ),
                              ),
                            );
                          },
                    child: Text('开始讨论${selected.isEmpty ? '' : ' (${selected.length}本)'}'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showBookMenu(Book book) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(60),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '《${book.title}》',
                style: Theme.of(context).textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('开始讨论'),
              subtitle: const Text('和 ta 一起聊聊这本书'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BookChatScreen(
                      bookId: book.id,
                      bookTitle: book.title,
                      bookAuthor: book.author,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('查看 Discussion'),
              subtitle: const Text('AI 帮你总结讨论笔记'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BookDiscussionScreen(
                      bookId: book.id,
                      bookTitle: book.title,
                      bookAuthor: book.author,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_stories),
              title: const Text('阅读档案'),
              subtitle: const Text('AI 提炼你的观点与感受'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ReadingProfileScreen(
                      bookId: book.id,
                      bookTitle: book.title,
                      bookAuthor: book.author,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Show a bottom sheet when book selections partially overlap with existing groups
  Future<String?> _showGroupPicker(
    BuildContext context,
    List<dynamic> overlapping, // DiscussionGroup
    List<Book> selectedBooks,
    Map<String, String?> previews,
  ) async {
    return showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 32, height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '发现相关讨论集合',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${selectedBooks.map((b) => '《${b.title}》').join('、')}',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
            ...overlapping.map((g) {
                  final preview = previews[g.id];
                  return ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(g.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${g.bookIds.where((id) => selectedBooks.any((b) => b.id == id)).length}本重叠'
                          ' · ${g.bookIds.length}本'
                          '${_timeAgo(g.updatedAt)}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                        ),
                        if (preview != null)
                          Text(
                            preview,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    onTap: () => Navigator.of(ctx).pop(g.id),
                  );
                }),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('新建独立集合'),
              subtitle: const Text('不关联到已有集合'),
              onTap: () => Navigator.of(ctx).pop('new'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return ' · ${diff.inDays}天前';
    if (diff.inHours > 0) return ' · ${diff.inHours}小时前';
    if (diff.inMinutes > 0) return ' · ${diff.inMinutes}分钟前';
    return ' · 刚刚';
  }

  void _viewCover(BuildContext context, Book book) {
    if (book.coverPath == null || !File(book.coverPath!).existsSync()) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('《${book.title}》封面')),
          backgroundColor: Colors.black,
          body: Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.file(File(book.coverPath!)),
            ),
          ),
        ),
      ),
    );
  }

  // ── Long-press → edit dialog (title / author / date / status / delete) ──
  Future<void> _editBook(Book book) async {
    final titleCtrl = TextEditingController(text: book.title);
    final authorCtrl = TextEditingController(text: book.author ?? '');
    final dateCtrl = TextEditingController(
      text:
          '${book.createdAt.year}-${book.createdAt.month.toString().padLeft(2, '0')}-${book.createdAt.day.toString().padLeft(2, '0')}',
    );
    var status = book.status;

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('编辑《${book.title}》'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: '书名',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: authorCtrl,
                  decoration: const InputDecoration(
                    labelText: '作者',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: dateCtrl,
                  decoration: const InputDecoration(
                    labelText: '添加日期',
                    hintText: 'YYYY-MM-DD',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                // status chooser
                Row(
                  children: [
                    const Text('阅读状态：'),
                    const SizedBox(width: 12),
                    DropdownButton<ReadingStatus>(
                      value: status,
                      items: ReadingStatus.values
                          .map((s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.label),
                              ))
                          .toList(),
                      onChanged: (s) {
                        if (s != null) setDlg(() => status = s);
                      },
                      underline: const SizedBox(),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                // change / view cover
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: Text(book.coverPath != null ? '更换封面' : '添加封面'),
                        onPressed: () async {
                          try {
                            final XFile? image = await _picker.pickImage(
                                source: ImageSource.gallery, maxWidth: 600);
                            if (image != null) {
                              final coverDir = await _coverDir;
                              final ext = image.path.split('.').last;
                              final fileName = '${_uuid.v4()}.$ext';
                              final dest = File('${coverDir.path}/$fileName');
                              await dest.writeAsBytes(await image.readAsBytes());
                              if (book.coverPath != null) {
                                try { await File(book.coverPath!).delete(); } catch (_) {}
                              }
                              book.coverPath = dest.path;
                              setDlg(() {});
                            }
                          } catch (_) {}
                        },
                      ),
                    ),
                    if (book.coverPath != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.zoom_in, size: 18),
                        label: const Text('查看'),
                        onPressed: () {
                          _viewCover(context, book);
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                // delete button
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    label: const Text('删除此书',
                        style: TextStyle(color: Colors.red)),
                    onPressed: () =>
                        Navigator.of(ctx).pop(<String, dynamic>{'delete': true}),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(<String, dynamic>{
                'title': titleCtrl.text.trim(),
                'author': authorCtrl.text.trim(),
                'date': dateCtrl.text.trim(),
                'status': status,
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    if (result['delete'] == true) {
      if (book.coverPath != null) {
        try { await File(book.coverPath!).delete(); } catch (_) {}
      }
      setState(() => _books.removeWhere((b) => b.id == book.id));
      await _saveBooks();
      return;
    }

    final newTitle = (result['title'] as String?)?.trim() ?? '';
    if (newTitle.isEmpty) return;
    setState(() {
      book.title = newTitle;
      book.author = (result['author'] as String?)?.trim();
      if ((result['author'] as String?)?.trim().isEmpty == true) {
        book.author = null;
      }
      // parse date
      try {
        final parts = (result['date'] as String).split('-');
        if (parts.length == 3) {
          book.status = result['status'] as ReadingStatus;
        }
      } catch (_) {}
      book.status = result['status'] as ReadingStatus;
    });
    await _saveBooks();
  }

  // ── Display helpers ──────────────────────────────────
  String _displayDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  Color _statusColor(ReadingStatus s, ThemeData theme) => switch (s) {
        ReadingStatus.wantToRead => theme.colorScheme.tertiary,
        ReadingStatus.reading => theme.colorScheme.primary,
        ReadingStatus.done => theme.colorScheme.secondary,
      };

  // ── Build ────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的书架'),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined),
            tooltip: '从微信读书导入',
            onPressed: _importFromWeread,
          ),
        ],
      ),
      body: Stack(
        children: [
          if (!_loaded)
            const Center(child: CircularProgressIndicator())
          else if (_books.isEmpty)
            _emptyState(theme)
          else
            Column(
              children: [
                _buildFilterChips(theme),
                Expanded(child: _bookGrid(theme)),
              ],
            ),
          // Discussing chip — bottom-left
          if (_books.isNotEmpty)
            Positioned(
              left: 16,
              bottom: 16,
              child: ActionChip(
                avatar: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Discussing...'),
                onPressed: () => _showDiscussingDialog(),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addBook,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildFilterChips(ThemeData theme) {
    final filtered = _filterStatus == null
        ? _books
        : _books.where((b) => b.status == _filterStatus).toList();
    final allCount = _books.length;
    final readingCount = _books.where((b) => b.status == ReadingStatus.reading).length;
    final doneCount = _books.where((b) => b.status == ReadingStatus.done).length;
    final wantCount = _books.where((b) => b.status == ReadingStatus.wantToRead).length;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _filterChip(theme, '全部 ($allCount)', null),
          const SizedBox(width: 8),
          _filterChip(theme, '在读 ($readingCount)', ReadingStatus.reading),
          const SizedBox(width: 8),
          _filterChip(theme, '已读 ($doneCount)', ReadingStatus.done),
          const SizedBox(width: 8),
          _filterChip(theme, '想读 ($wantCount)', ReadingStatus.wantToRead),
        ],
      ),
    );
  }

  Widget _filterChip(ThemeData theme, String label, ReadingStatus? status) {
    final active = _filterStatus == status;
    return FilterChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => setState(() => _filterStatus = active ? null : status),
      selectedColor: theme.colorScheme.primaryContainer,
      checkmarkColor: theme.colorScheme.primary,
    );
  }

  Widget _emptyState(ThemeData theme) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_rounded,
                size: 80, color: theme.colorScheme.primary.withAlpha(80)),
            const SizedBox(height: 16),
            Text('书架还是空的', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('点右下角 + 添加你的第一本书',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _bookGrid(ThemeData theme) {
    final filtered = _filterStatus == null
        ? _books
        : _books.where((b) => b.status == _filterStatus).toList();
    return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.48,
        ),
        itemCount: filtered.length,
        itemBuilder: (ctx, i) => _bookCard(theme, filtered[i]),
    );
  }

  Widget _bookCard(ThemeData theme, Book book) {
    final hasCover =
        book.coverPath != null && File(book.coverPath!).existsSync();
    final dateStr = _displayDate(book.createdAt);

    return GestureDetector(
      onTap: () => _showBookMenu(book),
      onDoubleTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${book.title}」讨论页面即将推出')),
        );
      },
      onLongPress: () => _editBook(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // cover image (2:3 portrait)
          Expanded(
            flex: 5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: hasCover
                  ? Image.file(File(book.coverPath!), fit: BoxFit.cover)
                  : _placeholderCover(theme, book),
            ),
          ),
          const SizedBox(height: 6),
          // info block
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '《${book.title}》',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                if (book.author != null)
                  Text(
                    book.author!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 4),
                // status badge + date
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _statusColor(book.status, theme),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      book.status.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _statusColor(book.status, theme),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      dateStr,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholderCover(ThemeData theme, Book book) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.menu_book_rounded,
                  size: 28,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(100)),
              const SizedBox(height: 6),
              Text(
                '《${book.title}》',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant.withAlpha(160),
                ),
              ),
              if (book.author != null) ...[
                const SizedBox(height: 2),
                Text(
                  book.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant.withAlpha(120),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}
