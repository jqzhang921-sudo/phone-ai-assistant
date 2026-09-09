import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';

import '../config/app_shape.dart';
import '../models/book.dart';
import '../models/musing_entry.dart';
import '../models/reading_note.dart';
import '../services/app_providers.dart';
import '../services/reading_note_store.dart';
import '../services/storage_service.dart';
import '../services/weread_service.dart';
import '../widgets/app_surface.dart';

/// 第三页：随笔和收藏。
///
/// ## 为什么是两个 tab，不是两块区域
///
/// 需求给了两个方案：「简单粗暴分两个区域」或者「做成笔记本」。我先做了前者
/// 的一个变体——上面两个切换，下面一列。
///
/// 分区（上下各一块）的问题是：两边都在增长，谁也不肯让地方。随笔写多了就把
/// 收藏挤没了，反过来也一样。切换至少保证每一边都能看全。
///
/// 笔记本那版留着，等她看过这个再定——那个更费工，而且好不好看得上手才知道。
class ReadingNotesScreen extends StatefulWidget {
  const ReadingNotesScreen({super.key});

  @override
  State<ReadingNotesScreen> createState() => _ReadingNotesScreenState();
}

class _ReadingNotesScreenState extends State<ReadingNotesScreen> {
  ReadingNoteKind _tab = ReadingNoteKind.essay;
  List<ReadingNote> _notes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final notes = await ReadingNoteStore.list();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  List<ReadingNote> get _visible =>
      _notes.where((n) => n.kind == _tab).toList();

  /// 聊天气泡上那朵花收藏的内容。
  ///
  /// ## 为什么要专门接一下
  ///
  /// 气泡上的收藏走的是 [FavoritesProvider]，主 App 里有「栖息」页能看。
  /// **读书版三个 tab 是讨论/书架/随笔，没有那一页**——于是收藏进去的东西
  /// 存是存下了，界面上一个入口都没有，用户只会以为「点了没反应，丢了」。
  ///
  /// 不合并进 [ReadingNoteStore]，是因为它们不归那个仓管：合并之后点进去
  /// 会走编辑，而编辑写回的是 store，等于把这条改没了。所以单独列、只读，
  /// 只给一个「取消收藏」。
  List<MusingEntry> get _favorites =>
      _tab == ReadingNoteKind.quote
          ? context.watch<FavoritesProvider>().entries
          : const [];

  Future<void> _compose({ReadingNote? editing}) async {
    final controller = TextEditingController(text: editing?.content ?? '');
    final isEssay = _tab == ReadingNoteKind.essay;
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder:
          (ctx) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              // 跟着键盘走，不然输入框被挡住。
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEssay ? '写点什么' : '记一句',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: isEssay ? 8 : 4,
                  minLines: isEssay ? 5 : 2,
                  decoration: InputDecoration(
                    hintText: isEssay ? '读完之后想到的⋯⋯' : '书里的那句话',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      () => Navigator.of(ctx).pop(controller.text.trim()),
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
    );

    if (text == null || text.isEmpty) return;
    if (editing != null) {
      await ReadingNoteStore.update(editing.copyWith(content: text));
    } else {
      await ReadingNoteStore.add(
        ReadingNote(
          id: 'n_${DateTime.now().microsecondsSinceEpoch}',
          kind: _tab,
          content: text,
          createdAt: DateTime.now(),
        ),
      );
    }
    _load();
  }

  /// 从微信读书导一本书的划线进来。
  ///
  /// 先让她选书，而不是一次导全部：一次导几十本会把这一页冲垮，
  /// 而且她多半只想要刚读完那本。
  Future<void> _importFromWeread() async {
    final books = await StorageService.listBooks();
    final withWeread = books.where((b) => b.wereadBookId != null).toList();
    if (!mounted) return;

    if (withWeread.isEmpty) {
      _toast('书架里还没有从微信读书导入的书');
      return;
    }

    final book = await showModalBottomSheet<Book>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('导入哪本书的划线'),
                ),
                for (final b in withWeread)
                  ListTile(
                    title: Text(b.title),
                    subtitle: b.author == null ? null : Text(b.author!),
                    onTap: () => Navigator.of(ctx).pop(b),
                  ),
              ],
            ),
          ),
    );
    if (book == null || !mounted) return;

    _toast('正在拉取⋯⋯');
    try {
      final raw = await WereadService.fetchHighlights(book.wereadBookId!);
      if (raw == null || raw.trim().isEmpty) {
        _toast('这本书没有划线');
        return;
      }
      // 接口返回的是一整段文本，按行切开，每行当一条。
      final lines = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      final added = await ReadingNoteStore.importQuotes(
        bookTitle: book.title,
        lines: lines,
      );
      if (!mounted) return;
      setState(() => _tab = ReadingNoteKind.quote);
      await _load();
      _toast(added == 0 ? '没有新的（都导过了）' : '导入了 $added 条');
    } catch (e) {
      _toast('拉取失败：$e');
    }
  }

  Future<void> _confirmClearImported() async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('清掉导入的划线'),
            content: const Text('只删从微信读书导进来的那些，你自己写的不动。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('清掉'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    final n = await ReadingNoteStore.clearImported();
    await _load();
    _toast(n == 0 ? '没有导入的内容' : '清掉了 $n 条');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = _visible;
    final favs = _favorites;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(child: _switcher(scheme)),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '从微信读书导入划线',
                  onPressed: _importFromWeread,
                  icon: Icon(
                    PhosphorIconsRegular.downloadSimple,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (_tab == ReadingNoteKind.quote)
                  IconButton(
                    tooltip: '清掉导入的',
                    onPressed: _confirmClearImported,
                    icon: Icon(
                      PhosphorIconsRegular.trash,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : (list.isEmpty && favs.isEmpty)
                    ? _empty(scheme)
                    : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        // 聊天里收的在前：那是刚发生的事。
                        itemCount: favs.length + list.length,
                        itemBuilder: (_, i) =>
                            i < favs.length
                                ? _favTile(favs[i], theme, scheme)
                                : _noteTile(
                                  list[i - favs.length],
                                  theme,
                                  scheme,
                                ),
                      ),
                    ),
          ),
        ],
      ),
    );
  }

  Widget _switcher(ColorScheme scheme) {
    Widget seg(ReadingNoteKind kind, String label) {
      final on = _tab == kind;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: () {
            if (_tab == kind) return;
            HapticFeedback.selectionClick();
            setState(() => _tab = kind);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: on ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return AppSurface(
      borderRadius: AppRadius.pillAll,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          children: [
            seg(ReadingNoteKind.essay, '随笔'),
            seg(ReadingNoteKind.quote, '收藏'),
          ],
        ),
      ),
    );
  }

  Widget _empty(ColorScheme scheme) {
    final isEssay = _tab == ReadingNoteKind.essay;
    return Stack(
      children: [
        // ListView 兜底，保证下拉刷新在空态也能用。
        ListView(),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              isEssay ? '还没写过什么\n右下角加一条' : '还没有收藏\n可以自己记，也可以从微信读书导',
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.7,
                fontSize: 13,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Positioned(
          right: 4,
          bottom: 12,
          child: FloatingActionButton.small(
            onPressed: _compose,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }

  /// 聊天里收藏的那一条。只读——它不归 [ReadingNoteStore] 管，
  /// 点进去走编辑会把它写丢。
  Widget _favTile(MusingEntry e, ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _showFav(e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.flowerLotus,
                      size: 13,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '聊天里收的',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  e.content,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFav(MusingEntry e) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  e.content,
                  style: const TextStyle(fontSize: 15, height: 1.8),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: e.content),
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      _toast('复制了');
                    },
                    child: const Text('复制'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: () async {
                      final nav = Navigator.of(ctx);
                      await context.read<FavoritesProvider>().remove(e.id);
                      nav.pop();
                      _toast('取消收藏了');
                    },
                    child: const Text('取消收藏'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _noteTile(ReadingNote note, ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _compose(editing: note),
          onLongPress: () => _askDelete(note),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.content,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                ),
                if (note.bookTitle != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '——《${note.bookTitle}》',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _askDelete(ReadingNote note) async {
    HapticFeedback.mediumImpact();
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            content: const Text('删掉这一条？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删掉'),
              ),
            ],
          ),
    );
    if (ok != true) return;
    await ReadingNoteStore.remove(note.id);
    _load();
  }
}
