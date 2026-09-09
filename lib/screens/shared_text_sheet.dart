import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../models/book.dart';
import '../models/reading_note.dart';
import '../services/reading_note_store.dart';
import '../services/shared_text.dart';
import '../services/storage_service.dart';
import 'book_chat_screen.dart';

/// 从别的 App 分享过来一段文字之后弹的那一张。
///
/// ## 为什么要弹一张，而不是直接跳进去
///
/// 分享过来的东西有两种：一本书（「我在番茄看《X》」）和一段原文。解析能分
/// 得**大概**准，但分不准的那几次，代价不对等——把一句原文当成书名扔进聊天，
/// 他得退出来重来；把一本书当成摘录存进收藏，他还得自己去删。
///
/// 所以让他看一眼再定。这一眼只花半秒，而且顺手解决了另一个问题：**分享过来
/// 的那段话常常没有出处**（长按选中分享的更是必然），书名只能问他。
Future<void> showSharedTextSheet(
  BuildContext context,
  SharedReading shared,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SharedTextSheet(shared: shared),
  );
}

class _SharedTextSheet extends StatefulWidget {
  final SharedReading shared;

  const _SharedTextSheet({required this.shared});

  @override
  State<_SharedTextSheet> createState() => _SharedTextSheetState();
}

class _SharedTextSheetState extends State<_SharedTextSheet> {
  late final _titleController = TextEditingController(
    text: widget.shared.bookTitle ?? '',
  );
  bool _busy = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  String get _title => _titleController.text.trim();

  /// 书架上有同名的就用那一条的身份进去，这样划线、作者、之前聊过的记录
  /// 全都接得上。跟首页「说本书」是同一套规矩——两个入口行为不一致，
  /// 用户是看不出原因的。
  Future<Book?> _matchBook() async {
    if (_title.isEmpty) return null;
    final books = await StorageService.listBooks();
    return books.where((b) => b.title.trim() == _title).firstOrNull;
  }

  Future<void> _chat() async {
    if (_title.isEmpty) return;
    setState(() => _busy = true);
    // ⚠️ 先把 Navigator 抓在手里。
    //
    // pop 之后这张表的 context 就失效了，再 `Navigator.of(context)` 会抛
    // 「looking up a deactivated widget's ancestor」。NavigatorState 本身
    // 活得比这张表久，抓着它就没事。
    final nav = Navigator.of(context);
    final known = await _matchBook();
    if (!mounted) return;
    nav.pop();
    await nav.push(
      MaterialPageRoute(
        builder: (_) => BookChatScreen(
          bookId: known?.id ?? 'adhoc_${_title.hashCode}',
          bookTitle: known?.title ?? _title,
          bookAuthor: known?.author,
          wereadBookId: known?.wereadBookId,
          // 原文填进输入框，不替他发出去——他多半还要在后面补一句自己的想法。
          initialInput: widget.shared.isExcerpt ? widget.shared.body : null,
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    // 同上：这两个都要在 pop 之前取，pop 之后 context 就没了。
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await ReadingNoteStore.add(
      ReadingNote(
        id: 'q_${DateTime.now().microsecondsSinceEpoch}',
        kind: ReadingNoteKind.quote,
        content: widget.shared.body,
        bookTitle: _title.isEmpty ? null : _title,
        // 标成导入的：他将来想「只清掉不是自己写的」时才分得开。
        imported: true,
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    nav.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('存进收藏了'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final excerpt = widget.shared.isExcerpt;

    return Padding(
      // 键盘弹起来的时候把整张顶上去，别把书名输入框压在下面。
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            excerpt ? '划到一段' : '要聊这本吗',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 14),
          if (excerpt) ...[
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.shared.body,
                  style: const TextStyle(fontSize: 14, height: 1.7),
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: _titleController,
            autofocus: excerpt && widget.shared.bookTitle == null,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: '哪本书',
              // 分享过来常常没有出处，这时候得问，但不能拦着——
              // 存一句不知道出处的话，也比逼他现在想起来强。
              hintText: excerpt ? '想不起来可以留空' : '书名',
              prefixIcon: Icon(
                PhosphorIconsRegular.bookOpen,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              if (excerpt) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('先存下来'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton(
                  // 聊天必须知道聊哪本——人设第一条就是围着这本书问。
                  // 存收藏可以不知道，所以只有这个按钮会灰掉。
                  onPressed: (_busy || _title.isEmpty) ? null : _chat,
                  child: Text(excerpt ? '就聊这段' : '开聊'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
