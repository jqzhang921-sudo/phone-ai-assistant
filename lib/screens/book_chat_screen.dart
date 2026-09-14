import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/reading_persona.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/discussion_note.dart';
import '../services/book_chat_store.dart';
import '../services/book_chat_streaming.dart';
import 'chat_export_screen.dart';
import '../services/book_lookup.dart';
import '../widgets/chat_message_item.dart';
import '../services/discussion_generator.dart';
import '../services/reader_traces.dart';
import '../services/app_providers.dart';
import '../config/app_shape.dart';

class BookChatScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;
  final String? bookAuthor;
  final String? wereadBookId;

  /// 进来时先填在输入框里的话（不自动发）。
  ///
  /// 从别的 App 分享一段原文过来时用：那段话已经在他脑子里了，让他还得
  /// 手动粘一遍就是白让他走一步。**但也不能替他发出去**——他多半还想在
  /// 后面补一句自己的想法，那句才是他真正要问的。
  final String? initialInput;

  const BookChatScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    this.bookAuthor,
    this.wereadBookId,
    this.initialInput,
  });

  @override
  State<BookChatScreen> createState() => _BookChatScreenState();
}

class _BookChatScreenState extends State<BookChatScreen>
    with BookChatStreaming<BookChatScreen> {
  @override
  final TextEditingController textController = TextEditingController();
  @override
  final ScrollController scrollController = ScrollController();
  final _uuid = const Uuid();

  @override
  late Conversation conversation;

  /// 读书版的人设见 [readingPersona]。
  ///
  /// 原来这里写的是「像两个读过这本书的朋友在聊天」——那是**平聊**：
  /// 你说一句我说一句，各自分享看法。听起来友好，但对着一个刚读完、
  /// 正处在「脑雾」里的人没用：他说不出来的时候，平聊就变成了 AI 独白。
  ///
  /// 换成引导型之后重心变了：**先把他心里的东西问出来**，再接住、再给。
  /// 换掉的理由和取舍全写在 reading_persona.dart 里。
  /// 三段拼起来：人设 + 查到的书目资料 + 他自己留下的东西。
  ///
  /// 顺序是有讲究的。资料在前、他的痕迹在后，因为**后面的更可信**：
  /// 书目资料可能查错了书，他划的句子不会。两段对不上的时候，
  /// 提示词里各自都写了「以用户为准」，位置再帮一把。
  @override
  String get systemPrompt {
    final base = readingPromptFor(
      title: widget.bookTitle,
      author: widget.bookAuthor,
    );
    final parts = <String>[base];
    final facts = _bookFacts;
    if (facts != null) parts.add(facts.asPromptBlock());
    final traces = _traces?.asPromptBlock();
    if (traces != null) parts.add(traces);
    return parts.join('\n\n');
  }

  /// 从微信读书查回来的这本书的资料。查不到就是 null，一切照旧。
  BookFacts? _bookFacts;

  /// 他自己在这本书里留下的东西（划线/想法/摘录/随笔）。
  ///
  /// 2026-09-09 之前这些只当成一条聊天气泡插在开头——**会被历史压缩折掉，
  /// 他自己也能删**，越往后聊 AI 手里的材料越少。现在改成常驻 system prompt，
  /// 理由全在 [ReaderTraces] 的注释里。
  ReaderTraces? _traces;

  /// 查询这两件事本身，用来让第一条消息等一等。
  ///
  /// 不等的话，**最该有资料的那一条恰好没有**：他进来就打字，查询还在路上，
  /// 第一轮照样空着手。而第一轮正是定调的那一轮。
  Future<void>? _lookup;

  /// 旧记录读完了没有。
  ///
  /// ⚠️ [_announceTraces] 必须等它——不等会**把历史覆盖掉**：
  /// `_loadConversation` 是从文件里读出来整个替换 `_conversation` 的，
  /// 而开头那条气泡的判据是「messages 是空的」。文件还没读回来时这个判据
  /// 恒为真，于是它插一条气泡、`_saveConversation()` 把**只有一条消息的
  /// 对话写回文件**，聊了半年的记录就没了。
  ///
  /// 原来这里也有同样的形状，只是那时候要等一个微信读书的网络往返才轮到它，
  /// 稳稳输给本地文件读取，撞不上。现在没配 key 的时候 [ReaderTraces.gather]
  /// 只读一次 SharedPreferences 就回来了——这个竞态是真会发生的。
  Future<void>? _loaded;

  @override
  void initState() {
    super.initState();
    conversation = Conversation(
      // 书名必须写进去：首页列单本讨论时就是读这个字段。
      // 不写的话默认是「新对话」，一整列全叫这个，等于没列。
      id: 'book_${widget.bookId}',
      title: widget.bookTitle,
      systemPrompt: systemPrompt,
    );
    _loaded = _loadConversation();
    // 两件事并行：一个走公网书库，一个走微信读书接口 + 本地，互不依赖。
    // 串起来等于把开聊前的等待翻倍。
    _lookup = Future.wait([_lookupBook(), _gatherTraces()]);
    final seed = widget.initialInput?.trim();
    if (seed != null && seed.isNotEmpty) textController.text = seed;
  }

  @override
  void dispose() {
    textController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  /// 单本讨论要发之前，先等书目查询和划线收集落地（最多 4 秒），
  /// 网不通的时候不能把他卡在这儿。
  @override
  Future<void> beforeTurn() async {
    final pending = _lookup;
    if (pending != null) {
      _lookup = null;
      // ⚠️ 查书、收划线失败了也**必须放行**。
      //
      // 这两件事只是给提示词添料。原来是直接 await：任何一个抛异常，异常就
      // 顺着 beforeTurn 冒出发送流程，isLoading 再也没人复位。2026-09-14
      // 《窄门》那条的样子：发出去五分钟，进度条一直在走，没有网络连接，
      // 没有报错，也没有回复。
      try {
        await pending.timeout(const Duration(seconds: 4), onTimeout: () {});
      } catch (e) {
        debugPrint('[book_chat] 开聊前的查询失败，跳过：$e');
      }
    }
  }

  /// 读旧记录 + 补上早期记录漏写的书名。
  Future<void> _loadConversation() async {
    await loadConversation();
    if (!mounted) return;
    // 老记录是在「书名没写进去」那版存的，标题会是「新对话」。
    // 每次打开补一次，旧记录也就跟着修好了。
    if (conversation.title != widget.bookTitle) {
      setState(() => conversation.title = widget.bookTitle);
    }
  }

  /// 开聊就查一次，不问模型的意见。
  ///
  /// 理由写在 [BookLookup] 的注释里：**模型不知道自己不知道**，指望它自己
  /// 想起来去搜，和指望它自己意识到没读过，是同一种指望。
  Future<void> _lookupBook() async {
    final facts = await BookLookup.fetch(
      title: widget.bookTitle,
      author: widget.bookAuthor,
    );
    if (facts == null || !mounted) return;
    setState(() {
      _bookFacts = facts;
      conversation.systemPrompt = systemPrompt;
    });
  }

  /// 收齐他自己留下的东西，塞进提示词，再在对话开头留一句话告诉他。
  Future<void> _gatherTraces() async {
    final traces = await ReaderTraces.gather(
      bookTitle: widget.bookTitle,
      wereadBookId: widget.wereadBookId,
    );
    if (traces.isEmpty || !mounted) return;
    setState(() {
      _traces = traces;
      conversation.systemPrompt = systemPrompt;
    });
    await _announceTraces(traces);
  }

  /// 开头那条气泡。
  ///
  /// 原来它把**所有划线原样贴出来**，一屏拉不到底——而那些话他自己写的，
  /// 他比谁都熟。现在内容走 system prompt，这条气泡只剩一个用处：
  /// 让他知道「它看过了」。所以只报数，不复读。
  Future<void> _announceTraces(ReaderTraces traces) async {
    // 先等旧记录落地，别拿一个还没读完的空对话当「全新对话」——
    // 理由见 [_loaded]，代价是整段历史。
    await _loaded;
    if (!mounted) return;
    // 只在全新的对话里说一次。聊过之后再插一条会打断上下文。
    if (conversation.messages.isNotEmpty) return;
    final bits = <String>[
      if (traces.highlightTotal > 0) '${traces.highlightTotal} 条划线',
      if (traces.thoughts.isNotEmpty) '${traces.thoughts.length} 条想法',
      if (traces.essays.isNotEmpty) '${traces.essays.length} 段随笔',
    ];
    if (bits.isEmpty) return;
    setState(() {
      conversation.messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content:
              '我看了你在《${widget.bookTitle}》里留下的${bits.join('、')}，'
              '心里有点数了。从哪儿说起都行。',
        ),
      );
    });
    saveConversation();
  }

  /// 退出不再拦。
  ///
  /// 原来每次离开都弹一张「要生成本次讨论的 Discussion 笔记吗？」，三个按钮：
  /// 不生成 / 保存对话 / 生成 Discussion。
  ///
  /// 三个问题：
  ///
  /// 1. **「保存对话」是假的选项**——每轮回复之后 [_saveConversation] 都已经
  ///    存过了。它在问一件早就发生的事，答什么都一样。
  /// 2. **拿常见情况去补贴罕见情况**。绝大多数离开就是离开；想要一份笔记是
  ///    偶尔的事。为了那偶尔一次，每一次退出都要多点一下。
  /// 3. 主 App 里还好，因为那边一场讨论是"一件事"，有始有终。读书版是随时
  ///    进去说两句就走的，退出频率高得多，同一张弹窗就从提示变成了拦路。
  ///
  /// 所以：**退出就是退出**，生成笔记挪进右上角的菜单——想要的时候去拿，
  /// 不想要的时候它不来找你。
  Future<void> _generateDiscussionNote() async {
    final messenger = ScaffoldMessenger.of(context);
    if (conversation.messages.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('还没聊什么')));
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('正在生成…'), duration: Duration(seconds: 2)),
    );
    await _generateAndSaveDiscussion();
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('笔记生成好了')));
  }

  Future<void> _generateAndSaveDiscussion() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;

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
      final prefs = await SharedPreferences.getInstance();
      final key = 'discussions_${widget.bookId}';
      final raw = prefs.getString(key);
      final list = raw != null ? (jsonDecode(raw) as List) : [];
      list.insert(0, note.toJson());
      await prefs.setString(key, jsonEncode(list));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('讨论笔记已生成')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('《${widget.bookTitle}》'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              final messenger = ScaffoldMessenger.of(context);
              if (v == 'refresh') {
                // 聊到一半又去划了几条是常事。重收一遍换掉提示词里那一段，
                // 而不是往对话里再贴一大块——贴出来的那块下一轮就被压缩了，
                // 换掉的这段能一直在。
                final traces = await ReaderTraces.gather(
                  bookTitle: widget.bookTitle,
                  wereadBookId: widget.wereadBookId,
                );
                if (!mounted) return;
                if (traces.isEmpty) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('没有找到划线或笔记')),
                  );
                  return;
                }
                setState(() {
                  _traces = traces;
                  conversation.systemPrompt = systemPrompt;
                });
                saveConversation();
                messenger.showSnackBar(
                  SnackBar(content: Text('已同步 ${traces.highlightTotal} 条划线')),
                );
              } else if (v == 'export') {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder:
                        (_) => ChatExportScreen(
                          messages: conversation.messages,
                          bookTitle: widget.bookTitle,
                          bookAuthor: widget.bookAuthor,
                        ),
                  ),
                );
              } else if (v == 'discussion') {
                await _generateDiscussionNote();
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder:
                      (ctx) => AlertDialog(
                        title: const Text('删除讨论'),
                        content: const Text('确定要删除当前讨论记录吗？删除后重新打开将导入微信读书划线。'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                );
                if (ok == true) {
                  await BookChatStore.remove(widget.bookId);
                  if (mounted) {
                    conversation.messages.clear();
                    setState(() {});
                    // 清空之后重新打一次招呼。材料本身在 systemPrompt 里，
                    // 删对话不会把它删掉，所以这里只要那一句气泡。
                    final traces = _traces;
                    if (traces != null) _announceTraces(traces);
                  }
                }
              }
            },
            itemBuilder:
                (ctx) => [
                  // 不再按 wereadBookId 置灰：现在它收的不止微信读书那一份，
                  // 第三页里写着这本书的摘录和随笔也一起收。手动加的书
                  // （「什么都不导入直接开聊」那条路）本来就没有 wereadBookId，
                  // 置灰等于把它们排除在外。
                  const PopupMenuItem(
                    value: 'refresh',
                    child: ListTile(
                      leading: Icon(PhosphorIconsRegular.arrowsClockwise),
                      title: Text('刷新划线'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'export',
                    child: ListTile(
                      leading: Icon(PhosphorIconsRegular.export),
                      title: Text('导出'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'discussion',
                    child: ListTile(
                      leading: Icon(PhosphorIconsRegular.notePencil),
                      title: Text('生成讨论笔记'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(PhosphorIconsRegular.trash),
                      title: Text('删除讨论'),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child:
              isLoading
                  ? const LinearProgressIndicator()
                  : const SizedBox.shrink(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child:
                conversation.messages.isEmpty
                    ? _buildEmptyState(theme)
                    : Builder(
                      builder: (context) {
                        // 读书版不拆气泡，理由见 groupChatItems 的注释。
                        final items = groupChatItems(
                          conversation.messages,
                          splitBubbles: false,
                        );
                        return ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: items.length,
                          itemBuilder:
                              (context, index) => chatDisplayItem(
                                items,
                                index,
                                conversationId: conversation.id,
                              ),
                        );
                      },
                    ),
          ),
          _buildInputArea(theme),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            PhosphorIconsRegular.bookOpen,
            size: 80,
            color: theme.colorScheme.primary.withAlpha(60),
          ),
          const SizedBox(height: 16),
          Text(
            '《${widget.bookTitle}》',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '开始聊聊这本书吧',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: textController,
              maxLines: 5,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '聊聊这本书...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 生成中禁用发送。原来这里切成一个 stop 图标，但 onPressed 是 null——
          // 一个点了没反应的停止键，比灰掉的发送键更骗人。真要「停止生成」
          // 得让 AiClient 支持流取消，那是另一件事。
          IconButton(
            icon: Icon(
              PhosphorIconsRegular.paperPlaneTilt,
              color:
                  isLoading
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
            ),
            onPressed: isLoading ? null : sendMessage,
          ),
        ],
      ),
    );
  }
}
