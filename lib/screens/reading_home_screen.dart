import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/api_keys.dart';
import '../config/app_shape.dart';
import '../models/book.dart';
import '../models/discussion_group.dart';
import '../services/book_chat_store.dart';
import '../services/discussion_group_service.dart';
import '../services/shared_text.dart';
import '../services/storage_service.dart';
import '../widgets/app_surface.dart';
import 'book_chat_screen.dart';
import 'chat_search_screen.dart';
import 'multi_book_chat_screen.dart';
import 'reading_settings_screen.dart';
import 'shared_text_sheet.dart';

/// 读书版首页：开一场新讨论，以及回到旧的那些。
///
/// ## 为什么开场不逼你先选书
///
/// 需求里第一条就是「什么都不导入，直接告诉他我看了什么书，然后开聊」。
/// 所以最上面那张卡是**空手就能进**的——书架是可选项，不是前置步骤。
///
/// 原来那套流程是「先加书 → 再点书 → 才能聊」。对一个刚读完一本书、
/// 脑子里正乱着的人来说，中间每多一步都是劝退。
class ReadingHomeScreen extends StatefulWidget {
  const ReadingHomeScreen({super.key});

  @override
  State<ReadingHomeScreen> createState() => _ReadingHomeScreenState();
}

class _ReadingHomeScreenState extends State<ReadingHomeScreen>
    with WidgetsBindingObserver {
  List<DiscussionGroup> _groups = const [];

  /// 单本讨论。
  ///
  /// 以前这一栏只列 [DiscussionGroup]，而 group 只有「多本一起聊」和书架
  /// 建组才会产生。**从「说本书」进去的记录一条都不出现**——偏偏那是主路径。
  /// 记录一直存着，只是没人读。见 [BookChatStore]。
  List<BookChatEntry> _chats = const [];

  List<Book> _books = const [];
  bool _loading = true;

  /// 没配 key 的时候，首页最上面会顶一条提示。
  ///
  /// 不这么做的话，新用户点「直接开聊」，进去发一句，收到的是「请先在设置中
  /// 配置 API Key」——那时候他已经走了三步，才知道第一步没做。
  bool _needsKey = false;

  /// 剪贴板里眼下有没有文字。
  ///
  /// ## 为什么最后是靠剪贴板
  ///
  /// 番茄的分享面板是它自己画的：微信、朋友圈、抖音、微博、QQ、生成分享图——
  /// 横着滑到头也**没有「系统分享」**。所以 `ACTION_SEND` 那条路（见
  /// `src/reading/AndroidManifest.xml`）根本够不着它。长按选中之后弹的那个
  /// 面板同样是自己画的，`ACTION_PROCESS_TEXT` 也接不上。
  ///
  /// 但那两个面板里都有**「复制」**。复制是每个阅读器都有的动作，比分享还
  /// 普遍，而且不归任何一家管——**这才是真正谁都拦不住的那条路**。
  ///
  /// ## 只问「有没有」，不看「是什么」
  ///
  /// [Clipboard.hasStrings] 走的是 `hasPrimaryClip` + 描述，**不读内容**，
  /// 所以不会触发安卓那条「读书讨论 已粘贴您复制的文本」的提示。
  /// 真去读是在他点了之后。
  ///
  /// 差别不只是少一条吐司：一个每次打开都偷看剪贴板的阅读 App，
  /// 本身就不该存在。
  bool _hasClip = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _checkClip();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台再看一次——他多半就是刚去番茄复制完才切回来的。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkClip();
  }

  Future<void> _checkClip() async {
    final has = await Clipboard.hasStrings();
    if (!mounted || has == _hasClip) return;
    setState(() => _hasClip = has);
  }

  /// 他点了，这才真去读。
  Future<void> _pasteIn() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    final parsed = text == null ? null : SharedReading.parse(text);
    if (parsed == null || parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('剪贴板里没有能用的文字'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await showSharedTextSheet(context, parsed);
    if (mounted) _load();
  }

  Future<void> _load() async {
    final groups = await DiscussionGroupService.listGroups();
    final chats = await BookChatStore.list();
    final books = await StorageService.listBooks();
    final configs = await ApiKeyService.loadKeys();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _chats = chats;
      _books = books;
      _needsKey = configs.every((c) => (c.apiKey ?? '').isEmpty);
      _loading = false;
    });
  }

  /// 空手开聊：问一句书名就进去。
  ///
  /// 不写进书架——他可能只是想聊一本路过的书，不想管理它。要不要收藏是
  /// 书架那一页的事，这里不替他决定。
  ///
  /// **但要先在书架里找一遍。** 同名的书如果已经在书架上（尤其是从微信读书
  /// 导进来的），就该用那一条的身份进去，这样划线、作者、以及之前聊过的记录
  /// 全都接得上。
  ///
  /// 第一版没做这个匹配，症状是「从这里进去拉不了划线，从书架进去可以」——
  /// 同一本书两个入口两种行为，而用户根本不知道为什么。
  Future<void> _startFresh() async {
    final title = await _askTitle();
    if (title == null || title.isEmpty || !mounted) return;

    final trimmed = title.trim();
    final known = _books.where((b) => b.title.trim() == trimmed).firstOrNull;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => BookChatScreen(
              // 书架上有就用它的身份；没有就用书名兜一个稳定的键，
              // 这样同一本书再聊也能接上上次的记录。
              bookId: known?.id ?? BookChatStore.adhocId(trimmed),
              bookTitle: known?.title ?? trimmed,
              bookAuthor: known?.author,
              wereadBookId: known?.wereadBookId,
            ),
      ),
    );
    _load();
  }

  Future<String?> _askTitle() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('聊哪本'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '书名就行，作者可写可不写'),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('开聊'),
              ),
            ],
          ),
    );
  }

  /// 回到一场单本讨论。
  ///
  /// 书架上有同名的就用那一条的身份进去——跟「说本书」和分享进来那两条路
  /// 同一套规矩。三个入口行为不一致的话，用户是看不出原因的。
  Future<void> _openChat(BookChatEntry chat) async {
    final known =
        _books.where((b) => b.id == chat.bookId).firstOrNull ??
        _books.where((b) => b.title.trim() == chat.title.trim()).firstOrNull;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => BookChatScreen(
              // bookId 用记录里那个，换了就接不上原来的对话文件。
              bookId: chat.bookId,
              bookTitle: known?.title ?? chat.title,
              bookAuthor: known?.author,
              wereadBookId: known?.wereadBookId,
            ),
      ),
    );
    _load();
  }

  /// 书架上有这本就用书架的名字。
  ///
  /// 记录里存的可能是老格式（那时候没写书名），也可能是用户当时随手打的
  /// 一个变体。书架那条是他自己整理过的，最可信。
  String _titleOf(BookChatEntry chat) {
    final known = _books.where((b) => b.id == chat.bookId).firstOrNull;
    return known?.title ?? chat.title;
  }

  Widget _chatTile(BookChatEntry chat, ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _openChat(chat),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _titleOf(chat),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      '${chat.messageCount} 条',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  // 最后说了什么，比「几条消息」更能让他认出是哪一场。
                  chat.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openGroup(DiscussionGroup group) async {
    final picked = _books.where((b) => group.bookIds.contains(b.id)).toList();
    if (picked.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiBookChatScreen(books: picked, groupId: group.id),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    // 问句，不是标语。
                    //
                    // 原来写的是「读完了，来聊聊」——那句里藏着一个预设：
                    // 假定人家已经读完了。可很多人是读到一半、或者刚翻两章
                    // 就想说点什么，那句话把他们挡在门外。
                    //
                    // 下面本来还有一句「说不清也没关系，我会问你」，删掉了：
                    // 那是在替自己做广告，把能力当卖点讲。好东西该让人用出来，
                    // 不是被告知。
                    '最近在看什么书',
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                IconButton(
                  tooltip: '搜聊过的内容',
                  icon: Icon(
                    PhosphorIconsRegular.magnifyingGlass,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: _openSearch,
                ),
                IconButton(
                  tooltip: '设置',
                  icon: Icon(
                    PhosphorIconsRegular.gearSix,
                    color: scheme.onSurfaceVariant,
                  ),
                  onPressed: _openSettings,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_needsKey) ...[
              _keyBanner(theme, scheme),
              const SizedBox(height: 12),
            ],
            _startCard(theme, scheme),
            // 剪贴板里没东西就不出现——摆一个点了会说「空的」的按钮，
            // 等于让他自己去发现这里没用。
            if (_hasClip) ...[
              const SizedBox(height: 8),
              _pasteCard(theme, scheme),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Text('聊过的书', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_groups.isNotEmpty || _chats.isNotEmpty)
                  Text(
                    '${_groups.length + _chats.length}',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_groups.isEmpty && _chats.isEmpty)
              _emptyHint(scheme)
            else ...[
              // 单本在前：它是主路径，多本讨论是偶尔为之。
              for (final c in _chats) _chatTile(c, theme, scheme),
              for (final g in _groups) _groupTile(g, theme, scheme),
            ],
          ],
        ),
      ),
    );
  }

  /// 搜聊过的内容。
  ///
  /// 单独一页而不是首页顶上一个输入框：首页上那两张大卡（说本书 / 粘一段）
  /// 是这一页的主张——**开了口就能聊**。顶上再压一个搜索框，等于一进门
  /// 先问「你要找旧的还是开新的」，而绝大多数时候答案是开新的。
  Future<void> _openSearch() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ChatSearchScreen()));
    _load();
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ReadingSettingsScreen()));
    _load();
  }

  /// 没填 key 时顶在最上面那条。做成可点的，点了直接去设置——
  /// 光提示不给路径，等于让他自己去翻。
  Widget _keyBanner(ThemeData theme, ColorScheme scheme) {
    return AppSurface(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _openSettings,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              Icon(
                PhosphorIconsRegular.warningCircle,
                size: 20,
                color: scheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '还没填模型 API Key，点这里去填',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Icon(
                PhosphorIconsRegular.caretRight,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _startCard(ThemeData theme, ColorScheme scheme) {
    return AppSurface(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _startFresh,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
          child: Row(
            children: [
              Icon(
                PhosphorIconsRegular.chatCircleDots,
                size: 26,
                color: scheme.primary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 上面那句已经在招呼了，这里只说动作，别再复述状态。
                    Text('说本书', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      '什么都不用导，说个书名就行',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                PhosphorIconsRegular.caretRight,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「粘一段进来」。压在「说本书」下面一档：多数时候他是来聊一本书的，
  /// 手里正好有一段才走这条。
  Widget _pasteCard(ThemeData theme, ColorScheme scheme) {
    return AppSurface(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: _pasteIn,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Row(
            children: [
              Icon(
                PhosphorIconsRegular.clipboardText,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('粘一段进来', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(
                      // 说清楚从哪儿来，否则他不知道这张卡是干嘛的。
                      '在番茄、起点、微信读书里复制一段，从这儿进来',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                PhosphorIconsRegular.caretRight,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyHint(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          '还没有聊过的书\n上面点一下就能开始',
          textAlign: TextAlign.center,
          style: TextStyle(
            height: 1.6,
            fontSize: 13,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 多本讨论的标。
  ///
  /// 多本和单本在「聊过的书」里本来长得一模一样：同一张卡、同样是标题 + 一行小字，
  /// 而群组名常常就是几本书名拼出来的——扫一眼分不出点进去是哪种。单本那行右侧
  /// 是「N 条」，这边就在同一个位置放个带底的标签：位置眼熟，样子不一样。
  ///
  /// 样式抄 `bookshelf_screen.dart` 的 `_statusPill`（同样 10.5 / w600 / 淡底），
  /// 两个页面看着才像一套。
  Widget _multiTag(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '多本',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _groupTile(
    DiscussionGroup group,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final titles = _books
        .where((b) => group.bookIds.contains(b.id))
        .map((b) => b.title)
        .join('、');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _openGroup(group),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _multiTag(scheme),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  // 书名列出来比「3本书」有用：她要认的是聊过什么，不是数量。
                  titles.isEmpty ? group.bookCountLabel : titles,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
