import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/book.dart';
import '../services/discussion_group_service.dart';
import '../services/app_providers.dart';
import '../services/weread_service.dart';
import '../widgets/app_surface.dart';
import 'book_chat_screen.dart';
import 'book_discussion_screen.dart';
import 'multi_book_chat_screen.dart';
import 'reading_profile_screen.dart';
import '../config/app_shape.dart';

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
  bool _searchOpen = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  static const _storageKey = 'bookshelf_books';
  static const _ignoredWereadKey = 'bookshelf_ignored_weread_ids';

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
          _books =
              list.map((j) => Book.fromJson(j as Map<String, dynamic>)).toList()
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

  /// 归一化标题用于去重比较：去首尾空格、合并中间多余空格。
  String _normalizeTitle(String title) =>
      title.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<Set<String>> _loadIgnoredWereadIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_ignoredWereadKey);
    return raw?.toSet() ?? {};
  }

  Future<void> _addIgnoredWereadId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = await _loadIgnoredWereadIds();
    ids.add(id);
    await prefs.setStringList(_ignoredWereadKey, ids.toList());
  }

  Future<void> _importFromWeread() async {
    // Check/save key
    var key = await WereadService.getKey();
    if (key == null || key.isEmpty) {
      if (!mounted) return;
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('微信读书 API Key'),
              content: TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  hintText: 'wrk-...',
                  border: OutlineInputBorder(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
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

      final ignoredIds = await _loadIgnoredWereadIds();

      // Update existing books with wereadBookId, add new books
      int updated = 0, added = 0, skipped = 0;
      for (final ib in imported) {
        if (ib.wereadBookId != null && ignoredIds.contains(ib.wereadBookId)) {
          skipped++;
          continue;
        }
        final ibTitle = _normalizeTitle(ib.title);
        final idx = _books.indexWhere(
          (b) => _normalizeTitle(b.title) == ibTitle,
        );
        if (idx >= 0) {
          if (_books[idx].wereadBookId == null && ib.wereadBookId != null) {
            _books[idx].wereadBookId = ib.wereadBookId;
            updated++;
          }
        } else {
          _books.add(ib);
          added++;
        }
      }

      if (added == 0 && updated == 0) {
        if (mounted) {
          final msg = skipped > 0 ? '没有新书（已跳过 $skipped 本忽略的书）' : '没有新书，书架已是最新';
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }

      await _saveBooks();
      if (mounted) {
        final parts = <String>[];
        if (added > 0) parts.add('新增 $added 本');
        if (updated > 0) parts.add('更新 $updated 本');
        if (skipped > 0) parts.add('跳过 $skipped 本忽略的书');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(parts.join('，'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  // ── Add ──────────────────────────────────────────────
  Future<void> _addBook() async {
    final titleCtrl = TextEditingController();
    final authorCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
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
      builder:
          (ctx) => AlertDialog(
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
        final XFile? image = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 600,
        );
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
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setSheet) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant.withAlpha(60),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '选择要讨论的书',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
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
                              subtitle:
                                  book.author != null
                                      ? Text(book.author!)
                                      : null,
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
                            onPressed:
                                selected.isEmpty
                                    ? null
                                    : () async {
                                      Navigator.of(ctx).pop();
                                      final books =
                                          _books
                                              .where(
                                                (b) => selected.contains(b.id),
                                              )
                                              .toList();
                                      final bookIds =
                                          books.map((b) => b.id).toList();

                                      // Check for exact match first
                                      final exact =
                                          await DiscussionGroupService.findExactMatch(
                                            bookIds,
                                          );
                                      if (exact != null) {
                                        // Directly enter existing group
                                        if (!mounted) return;
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder:
                                                (_) => MultiBookChatScreen(
                                                  books: books,
                                                  groupId: exact.id,
                                                ),
                                          ),
                                        );
                                        return;
                                      }

                                      // Check for partial overlap
                                      final overlapping =
                                          await DiscussionGroupService.findGroupsContaining(
                                            bookIds,
                                          );
                                      String? groupId;

                                      // Load last-message previews for each group
                                      final previews = <String, String?>{};
                                      for (final g in overlapping) {
                                        previews[g.id] =
                                            await DiscussionGroupService.lastMessagePreview(
                                              g.id,
                                            );
                                      }

                                      if (overlapping.isNotEmpty && mounted) {
                                        groupId = await _showGroupPicker(
                                          context,
                                          overlapping,
                                          books,
                                          previews,
                                        );
                                        if (groupId == null) {
                                          return; // cancelled
                                        }
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
                                          builder:
                                              (_) => MultiBookChatScreen(
                                                books: books,
                                                groupId: groupId,
                                              ),
                                        ),
                                      );
                                    },
                            child: Text(
                              '开始讨论${selected.isEmpty ? '' : ' (${selected.length}本)'}',
                            ),
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
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withAlpha(60),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
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
                const SizedBox(height: 4),
                // 加入书架的日期。书卡上不再铺它了——一屏十几个日期是噪音，
                // 但真要看的时候得找得到，所以落在这儿。
                Text(
                  '加入于 ${_displayDate(book.createdAt)}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.chatCircle),
                  title: const Text('开始讨论'),
                  subtitle: const Text('和 ta 一起聊聊这本书'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (_) => BookChatScreen(
                              bookId: book.id,
                              bookTitle: book.title,
                              bookAuthor: book.author,
                              wereadBookId: book.wereadBookId,
                            ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.sparkle),
                  title: const Text('查看 Discussion'),
                  subtitle: const Text('AI 帮你总结讨论笔记'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (_) => BookDiscussionScreen(
                              bookId: book.id,
                              bookTitle: book.title,
                              bookAuthor: book.author,
                            ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.books),
                  title: const Text('阅读档案'),
                  subtitle: const Text('AI 提炼你的观点与感受'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (_) => ReadingProfileScreen(
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
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
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
                    selectedBooks.map((b) => '《${b.title}》').join('、'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                ...overlapping.map((g) {
                  final preview = previews[g.id];
                  return ListTile(
                    leading: const Icon(PhosphorIconsRegular.folder),
                    title: Text(g.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${g.bookIds.where((id) => selectedBooks.any((b) => b.id == id)).length}本重叠'
                          ' · ${g.bookIds.length}本'
                          '${_timeAgo(g.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (preview != null)
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                  leading: const Icon(PhosphorIconsRegular.plusCircle),
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
        builder:
            (_) => Scaffold(
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
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setDlg) => AlertDialog(
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
                              items:
                                  ReadingStatus.values
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: s,
                                          child: Text(s.label),
                                        ),
                                      )
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
                                icon: const Icon(
                                  PhosphorIconsRegular.image,
                                  size: 18,
                                ),
                                label: Text(
                                  book.coverPath != null ? '更换封面' : '添加封面',
                                ),
                                onPressed: () async {
                                  try {
                                    final XFile? image = await _picker
                                        .pickImage(
                                          source: ImageSource.gallery,
                                          maxWidth: 600,
                                        );
                                    if (image != null) {
                                      final coverDir = await _coverDir;
                                      final ext = image.path.split('.').last;
                                      final fileName = '${_uuid.v4()}.$ext';
                                      final dest = File(
                                        '${coverDir.path}/$fileName',
                                      );
                                      await dest.writeAsBytes(
                                        await image.readAsBytes(),
                                      );
                                      if (book.coverPath != null) {
                                        try {
                                          await File(book.coverPath!).delete();
                                        } catch (_) {}
                                      }
                                      book.coverPath = dest.path;
                                      setDlg(() {});
                                      // 立刻落盘，同「移除封面」。
                                      //
                                      // 上面两步已经不可逆地动过文件了（旧封面
                                      // 删了、新图写了）。不在这里存，用户点
                                      // 「取消」就会留下「JSON 里的 coverPath 还
                                      // 指着已删的旧文件」——当场看着是换好了
                                      // （内存对象已改），下次启动封面反而没了，
                                      // 新图还留在 book_covers 里成孤儿。
                                      // 「取消」只该撤销书名/作者/日期/状态。
                                      await _saveBooks();
                                      if (mounted) setState(() {});
                                    }
                                  } catch (_) {}
                                },
                              ),
                            ),
                            // 「查看 / 移除」收成图标按钮，跟「更换封面」挤在同一行。
                            //
                            // 之前把「移除封面」单独做成一行右对齐的红字，视觉上像
                            // 块飘着的补丁，而且和下面真正危险的「删除此书」抢同一个
                            // 红色。移除封面并不危险——重新加一张就回来了，所以这里
                            // 用中性色，红色留给删书。
                            if (book.coverPath != null) ...[
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(
                                  PhosphorIconsRegular.magnifyingGlassPlus,
                                  size: 20,
                                ),
                                tooltip: '查看封面',
                                visualDensity: VisualDensity.compact,
                                onPressed: () {
                                  _viewCover(context, book);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  PhosphorIconsRegular.imageBroken,
                                  size: 20,
                                ),
                                tooltip: '移除封面',
                                visualDensity: VisualDensity.compact,
                                color:
                                    Theme.of(ctx).colorScheme.onSurfaceVariant,
                                onPressed: () async {
                                  // 立刻落盘，不等外面点「保存」。
                                  //
                                  // 上面「更换封面」是改完内存等保存，用户点取消就会
                                  // 留下「文件已经换了、coverPath 却没存」的错位。
                                  // 移除这条路不跟着错：图片文件删了就是删了，撤不
                                  // 回来，那持久化的状态也应该当场对齐。
                                  final old = book.coverPath;
                                  book.coverPath = null;
                                  setDlg(() {});
                                  if (old != null) {
                                    try {
                                      await File(old).delete();
                                    } catch (_) {}
                                  }
                                  await _saveBooks();
                                  if (mounted) setState(() {});
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
                            icon: const Icon(
                              PhosphorIconsRegular.trash,
                              color: Colors.red,
                            ),
                            label: const Text(
                              '删除此书',
                              style: TextStyle(color: Colors.red),
                            ),
                            onPressed:
                                () => Navigator.of(
                                  ctx,
                                ).pop(<String, dynamic>{'delete': true}),
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
                      onPressed:
                          () => Navigator.of(ctx).pop(<String, dynamic>{
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
      // 确认删除之后才震，不是点开菜单就震
      HapticFeedback.mediumImpact();
      if (book.coverPath != null) {
        try {
          await File(book.coverPath!).delete();
        } catch (_) {}
      }
      if (book.wereadBookId != null) {
        await _addIgnoredWereadId(book.wereadBookId!);
      }
      setState(() => _books.removeWhere((b) => b.id == book.id));
      await _saveBooks();
      if (mounted && book.wereadBookId != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已删除，下次从微信读书导入不会再拉回这本书')));
      }
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
      // 走 changeStatus 而不是直接赋值：finishedAt 要跟着一起维护，
      // 「这段时间读完的书」是写信时的素材来源之一。
      //
      // 原来这里在 date 解析的 try 里还赋值了一次 status，和下面这句重复，
      // 顺手去掉——日期本身从来没被解析进 book。
      book.changeStatus(result['status'] as ReadingStatus);
    });
    await _saveBooks();
  }

  // ── Display helpers ──────────────────────────────────
  String _displayDate(DateTime d) =>
      '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

  // 在读用主色，其余一律走唯一那档次级灰。
  // 别用 secondary —— 那是装饰用的浅棕，当文字色在奶白底上只有 1.5:1。

  // ── Build ────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        // 不加副标题：下面那条分段控件已经把「全部 39 / 在读 5」写清楚了
        title: Text('我的书架', style: TextStyle(color: fgColor)),
        actions: [
          SizedBox(
            height: 36,
            child: AppSurface(
              borderRadius: AppRadius.pillAll,
              floating: true,
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _searchOpen
                          ? PhosphorIconsRegular.magnifyingGlassMinus
                          : PhosphorIconsRegular.magnifyingGlass,
                      size: 20,
                    ),
                    tooltip: '搜索书架',
                    onPressed: () {
                      setState(() {
                        _searchOpen = !_searchOpen;
                        if (!_searchOpen) {
                          _searchController.clear();
                          _searchQuery = '';
                        }
                      });
                    },
                  ),
                  IconButton(
                    icon: const Icon(
                      PhosphorIconsRegular.chatCircleText,
                      size: 20,
                    ),
                    tooltip: '发起讨论',
                    onPressed: _books.isEmpty ? null : _showDiscussingDialog,
                  ),
                  IconButton(
                    icon: const Icon(
                      PhosphorIconsRegular.cloudArrowDown,
                      size: 20,
                    ),
                    tooltip: '从微信读书导入',
                    onPressed: _importFromWeread,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body:
          !_loaded
              ? const Center(child: CircularProgressIndicator())
              : _books.isEmpty
              ? _emptyState(theme)
              : Column(
                children: [
                  if (_searchOpen) _buildSearchField(theme),
                  _buildFilterChips(theme),
                  Expanded(child: _bookGrid(theme)),
                ],
              ),
      // 不用为导航胶囊留位置：home_shell 里胶囊是 Column 的一员，
      // 这个 Scaffold 本来就止于它上方。
      floatingActionButton: FloatingActionButton(
        onPressed: _addBook,
        shape: const CircleBorder(),
        child: const Icon(PhosphorIconsRegular.plus),
      ),
    );
  }

  Widget _buildSearchField(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '搜书名或作者',
          prefixIcon: const Icon(
            PhosphorIconsRegular.magnifyingGlass,
            size: 20,
          ),
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide.none,
          ),
          suffixIcon:
              _searchQuery.isEmpty
                  ? null
                  : IconButton(
                    icon: const Icon(PhosphorIconsRegular.x, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  Widget _buildFilterChips(ThemeData theme) {
    final allCount = _books.length;
    final readingCount =
        _books.where((b) => b.status == ReadingStatus.reading).length;
    final doneCount =
        _books.where((b) => b.status == ReadingStatus.done).length;
    final wantCount =
        _books.where((b) => b.status == ReadingStatus.wantToRead).length;

    const items = [
      (null, '全部'),
      (ReadingStatus.reading, '在读'),
      (ReadingStatus.done, '已读'),
      (ReadingStatus.wantToRead, '想读'),
    ];
    final counts = {
      null: allCount,
      ReadingStatus.reading: readingCount,
      ReadingStatus.done: doneCount,
      ReadingStatus.wantToRead: wantCount,
    };
    // 四格等宽的一条，不是四个各自带边框的独立 chip——
    // 独立 chip 是四个碎块，分段控件是一个整体。
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
      child: AppSurface(
        borderRadius: AppRadius.pillAll,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Row(
            children: [
              for (final (status, label) in items)
                Expanded(
                  child: _segment(theme, '$label ${counts[status]}', status),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(ThemeData theme, String label, ReadingStatus? status) {
    final scheme = theme.colorScheme;
    final active = _filterStatus == status;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _filterStatus = status),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          // 选中用淡底，不用实色主色——实色太重
          color: active ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          PhosphorIconsRegular.bookOpen,
          size: 80,
          color: theme.colorScheme.primary.withAlpha(80),
        ),
        const SizedBox(height: 16),
        Text('书架还是空的', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '点右下角 + 添加你的第一本书',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _bookGrid(ThemeData theme) {
    var filtered =
        _filterStatus == null
            ? _books
            : _books.where((b) => b.status == _filterStatus).toList();
    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      filtered =
          filtered
              .where(
                (b) =>
                    b.title.toLowerCase().contains(q) ||
                    (b.author?.toLowerCase().contains(q) ?? false),
              )
              .toList();
    }
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '没找到匹配的书',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    // 用 mainAxisExtent 把每格高度算死：封面固定 2:3，下面文字块定高。
    // childAspectRatio 是宽高比，换个屏宽就要重新试数，不如直接算。
    return LayoutBuilder(
      builder: (ctx, c) {
        const pad = 20.0, gap = 20.0;
        final itemW = (c.maxWidth - pad * 2 - gap) / 2;
        return GridView.builder(
          // 玻璃卡片的 BackdropFilter 要采样身后的背景图，每项默认套的
          // RepaintBoundary 会把两者隔开，滚动时「先透明再模糊」。
          addRepaintBoundaries: false,
          padding: const EdgeInsets.fromLTRB(pad, 2, pad, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 18,
            crossAxisSpacing: gap,
            mainAxisExtent: itemW * 1.5 + 104,
          ),
          itemCount: filtered.length,
          itemBuilder: (ctx, i) => _bookCard(theme, filtered[i]),
        );
      },
    );
  }

  Widget _bookCard(ThemeData theme, Book book) {
    final hasCover =
        book.coverPath != null && File(book.coverPath!).existsSync();

    return GestureDetector(
      onTap: () => _showBookMenu(book),
      onDoubleTap: () {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('「${book.title}」讨论页面即将推出')));
      },
      onLongPress: () => _editBook(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 封面直接落在页面底色上，不再套白卡——白卡把每本书框成一个小盒子，
          // 一屏十几个盒子就是十几条边。层次交给封面自己的投影。
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: AppShadow.softenCover(
                  theme.brightness == Brightness.dark,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child:
                    hasCover
                        ? Image.file(File(book.coverPath!), fit: BoxFit.cover)
                        : _placeholderCover(theme, book),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // 一根右端渐隐的发丝线，把书名和封面绑在一起。
          // 实线会变成新的碎线；渐变线读起来是一道光，不是边框。
          Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withValues(alpha: 0.30),
                  theme.colorScheme.primary.withValues(alpha: 0.03),
                ],
              ),
            ),
          ),
          const SizedBox(height: 9),
          Expanded(
            child: ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '《${book.title}》',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  if (book.author != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      book.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _statusPill(theme, book),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(ThemeData theme, Book book) {
    final scheme = theme.colorScheme;
    // 只有「在读」值得上主色，另外两档是背景信息
    final reading = book.status == ReadingStatus.reading;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color:
            reading
                ? scheme.primary.withValues(alpha: 0.11)
                : scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        book.status.label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: reading ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _placeholderCover(ThemeData theme, Book book) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(color: scheme.primaryContainer),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: 0.75,
              child: Image.asset(
                'assets/icons/books.png',
                height: 26,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '《${book.title}》',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
                color: scheme.onPrimaryContainer,
              ),
            ),
            if (book.author != null) ...[
              const SizedBox(height: 3),
              Text(
                book.author!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
