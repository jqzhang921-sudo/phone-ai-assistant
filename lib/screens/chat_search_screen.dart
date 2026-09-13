import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../models/book.dart';
import '../services/book_chat_search.dart';
import '../services/storage_service.dart';
import '../widgets/app_surface.dart';
import 'book_chat_screen.dart';

/// 搜聊过的内容。
///
/// 首页那一栏是按书排的，能认出自己那本书的前提是**记得书名**。而想找的时候
/// 往往反过来：记得的是某次聊到的一句话（「上次说的那个什么效应来着」），
/// 书名早忘了。那时候按书排的列表一点忙都帮不上，只能一本本点进去翻。
///
/// 所以这一页搜的是**消息本身**。书名照样搜得到——它写在每条结果上面——
/// 但主路径是「记得一句话，找回那场对话」。
class ChatSearchScreen extends StatefulWidget {
  const ChatSearchScreen({super.key});

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final _controller = TextEditingController();

  /// 全部内容一次读进内存，之后每次过滤都是纯内存比较。
  /// 理由见 [BookChatSearch.load]。
  List<SearchableChat> _all = const [];
  List<Book> _books = const [];
  bool _loading = true;

  /// 跟着输入框走的当前结果。
  List<ChatSearchHit> _hits = const [];
  List<String> _terms = const [];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refilter);
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final chats = await BookChatSearch.load();
    final books = await StorageService.listBooks();
    if (!mounted) return;
    setState(() {
      _all = chats;
      _books = books;
      _loading = false;
    });
    _refilter();
  }

  /// 在内存里重算一遍。没有防抖：几十场讨论的纯字符串比较是微秒级的，
  /// 加个 250ms 的延迟只会让结果看起来慢半拍。
  void _refilter() {
    final q = _controller.text;
    setState(() {
      _terms = BookChatSearch.terms(q);
      _hits = BookChatSearch.run(_all, _terms);
    });
  }

  /// 进到那场讨论里去。
  ///
  /// 书架上有这本就用书架那条的身份——跟首页、跟「说本书」同一套规矩。
  /// 三个入口认书的方式不一致的话，用户是看不出原因的。
  Future<void> _open(ChatSearchHit hit) async {
    final known =
        _books.where((b) => b.id == hit.bookId).firstOrNull ??
        _books.where((b) => b.title.trim() == hit.title.trim()).firstOrNull;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => BookChatScreen(
              // bookId 用记录里那个，换了就接不上原来的对话文件。
              bookId: hit.bookId,
              bookTitle: known?.title ?? hit.title,
              bookAuthor: known?.author,
              wereadBookId: known?.wereadBookId,
            ),
      ),
    );
    // 回来重读一次：他在里面可能刚删了这场对话，结果列表得跟着变，
    // 别让一条已经删掉的记录继续挂在屏幕上等着他再点进去。
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        // 搜索框就是标题栏本身：这一页除了搜没别的事，多一行标题只是
        // 把他要的东西往下压一行。
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.titleMedium,
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: '搜聊过的内容',
            hintStyle: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.normal,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              tooltip: '清空',
              icon: const Icon(PhosphorIconsRegular.x),
              onPressed: _controller.clear,
            ),
        ],
      ),
      body: _body(theme, scheme),
    );
  }

  Widget _body(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_terms.isEmpty) {
      return _hint(
        scheme,
        _all.isEmpty ? '还没有聊过的书' : '搜你说过的话，也搜它说过的话\n一共 ${_all.length} 场讨论',
      );
    }
    if (_hits.isEmpty) {
      return _hint(scheme, '没搜到「${_controller.text.trim()}」');
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      // 玻璃卡片在滚动列表里要关掉这层，否则采样跟不上位移会闪。
      // 理由见 AppSurface 的注释。
      addRepaintBoundaries: false,
      itemCount: _hits.length,
      itemBuilder: (context, i) => _hitTile(_hits[i], theme, scheme),
    );
  }

  Widget _hitTile(ChatSearchHit hit, ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _open(hit),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      // 谁说的，决定这句话该怎么读——是他自己的旧念头，
                      // 还是它当初的回答。
                      hit.isUser
                          ? PhosphorIconsRegular.user
                          : PhosphorIconsRegular.sparkle,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        hit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (hit.at != null)
                      Text(
                        _when(hit.at!),
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text.rich(
                  TextSpan(children: _spans(hit.snippet, scheme)),
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _hint(ColorScheme scheme, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            height: 1.7,
            fontSize: 13,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 把命中的词在片段里标出来。
  ///
  /// 自己切片段而不是整段套一个底色：一段里可能命中好几个词、位置还不一样，
  /// 只有把区间切出来才标得准。
  List<TextSpan> _spans(String text, ColorScheme scheme) {
    final lower = text.toLowerCase();
    final marks = <List<int>>[];
    for (final t in _terms) {
      var from = 0;
      while (true) {
        final i = lower.indexOf(t, from);
        if (i < 0) break;
        marks.add([i, i + t.length]);
        from = i + t.length;
      }
    }
    if (marks.isEmpty) return [TextSpan(text: text)];

    // 重叠的区间先合并——嵌套的 span 会打架，而且视觉效果没有任何区别。
    marks.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[];
    for (final m in marks) {
      if (merged.isNotEmpty && m[0] <= merged.last[1]) {
        if (m[1] > merged.last[1]) merged.last[1] = m[1];
      } else {
        merged.add([m[0], m[1]]);
      }
    }

    final spans = <TextSpan>[];
    var at = 0;
    for (final m in merged) {
      // 下标是在小写副本上算的，而 `toLowerCase()` 极少数情况下会改变长度
      // （İ 会变成 i 加一个组合符，两个码元）。真有这种字符时算出来的下标
      // 可能落在正文外面——夹一下：宁可少标一个词，也不能让 substring
      // 越界把整页崩掉。
      final start = m[0].clamp(at, text.length);
      final end = m[1].clamp(start, text.length);
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      if (end > start) {
        spans.add(
          TextSpan(
            text: text.substring(start, end),
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w600,
              backgroundColor: scheme.primary.withValues(alpha: 0.10),
            ),
          ),
        );
      }
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return spans;
  }

  /// 「今天」「昨天」「3 天前」，再远就写日期。
  ///
  /// 搜索结果的用处是「对上号」，所以要比具体时刻宽一点——他要认的是
  /// 「哦是那阵子聊的」，不是分秒。
  String _when(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = today.difference(DateTime(t.year, t.month, t.day)).inDays;
    if (days <= 0) return '今天';
    if (days == 1) return '昨天';
    if (days < 7) return '$days 天前';
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }
}
