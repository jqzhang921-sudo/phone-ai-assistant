import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/reading_persona.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/discussion_note.dart';
import '../services/ai_client.dart';
import '../services/book_chat_store.dart';
import 'chat_export_screen.dart';
import '../services/book_lookup.dart';
import '../services/mcp_server.dart';
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

class _BookChatScreenState extends State<BookChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  bool _isLoading = false;

  late Conversation _conversation;

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
  String get _systemPrompt {
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
    _conversation = Conversation(
      // 书名必须写进去：首页列单本讨论时就是读这个字段。
      // 不写的话默认是「新对话」，一整列全叫这个，等于没列。
      id: 'book_${widget.bookId}',
      title: widget.bookTitle,
      systemPrompt: _systemPrompt,
    );
    _loaded = _loadConversation();
    // 两件事并行：一个走公网书库，一个走微信读书接口 + 本地，互不依赖。
    // 串起来等于把开聊前的等待翻倍。
    _lookup = Future.wait([_lookupBook(), _gatherTraces()]);
    final seed = widget.initialInput?.trim();
    if (seed != null && seed.isNotEmpty) _textController.text = seed;
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
      _conversation.systemPrompt = _systemPrompt;
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
      _conversation.systemPrompt = _systemPrompt;
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
    if (_conversation.messages.isNotEmpty) return;
    final bits = <String>[
      if (traces.highlightTotal > 0) '${traces.highlightTotal} 条划线',
      if (traces.thoughts.isNotEmpty) '${traces.thoughts.length} 条想法',
      if (traces.essays.isNotEmpty) '${traces.essays.length} 段随笔',
    ];
    if (bits.isEmpty) return;
    setState(() {
      _conversation.messages.add(
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content:
              '我看了你在《${widget.bookTitle}》里留下的${bits.join('、')}，'
              '心里有点数了。从哪儿说起都行。',
        ),
      );
    });
    _saveConversation();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 目录归 [BookChatStore] 管——首页也要读同一个地方，
  /// 两处各写一份路径迟早会分叉。
  Future<Directory> get _bookConvDir => BookChatStore.dir();

  Future<void> _loadConversation() async {
    try {
      final dir = await _bookConvDir;
      final file = File('${dir.path}/${_conversation.id}.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        setState(() {
          _conversation = Conversation.fromJson(data);
          // always refresh system prompt to latest
          _conversation.systemPrompt = _systemPrompt;
          // 老记录是在「书名没写进去」那版存的，标题会是「新对话」。
          // 每次打开补一次，旧记录也就跟着修好了。
          _conversation.title = widget.bookTitle;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConversation() async {
    final dir = await _bookConvDir;
    final file = File('${dir.path}/${_conversation.id}.json');
    await file.writeAsString(jsonEncode(_conversation.toJson()));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isLoading) return;
    _textController.clear();

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: text,
    );

    setState(() {
      _conversation.messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();
    _continueChat();
  }

  Future<void> _continueChat() async {
    // 等查询落地再发，但最多等 4 秒——网不通的时候不能把他卡在这儿。
    // BookLookup 自己也有 6 秒超时，这一层只是为了「他打字比网快」那一下。
    final pending = _lookup;
    if (pending != null) {
      _lookup = null;
      await pending.timeout(const Duration(seconds: 4), onTimeout: () {});
      if (!mounted) return;
    }

    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;

    if (aiClient == null) {
      setState(() {
        _conversation.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: '请先在设置中配置 API Key',
          ),
        );
        _isLoading = false;
      });
      return;
    }

    final allTools = [
      ...mcpServer.registeredTools.map((r) => r.tool),
      ...externalTools,
    ];
    final clientWithTools = AiClient(config: aiClient.config, tools: allTools);

    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;
      String? fullResponse;
      // 思考单独攒，不进 fullResponse——那个要发回服务端当上文。
      String? thinkingBuffer;

      try {
        await for (final event in clientWithTools.chat(
          _conversation.messages,
          systemPrompt: _conversation.systemPrompt,
        )) {
          switch (event.type) {
            // 读书版**要**显示思考。
            //
            // 引导型的价值在于「它为什么这么问」——看见推理过程，比只看见
            // 那个问题有用得多。主 App 那边思考是附加信息，这边它本身就是
            // 内容的一部分。
            case AiEventType.thinking:
              thinkingBuffer = (thinkingBuffer ?? '') + (event.text ?? '');
              _updateAssistantMessage(
                fullResponse ?? '',
                thinking: thinkingBuffer,
              );
              break;

            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              _updateAssistantMessage(fullResponse);
              break;

            case AiEventType.toolCalls:
              _updateAssistantMessage(
                fullResponse ?? '',
                toolCalls: event.toolCalls ?? [],
              );
              _finalizeStreamMessage();
              for (final tc in event.toolCalls ?? []) {
                final toolResult = await _executeTool(mcpServer, tc);
                _conversation.messages.add(
                  ChatMessage(
                    id: _uuid.v4(),
                    role: MessageRole.toolResult,
                    content: toolResult,
                    toolCallId: tc.id,
                  ),
                );
              }
              fullResponse = null;
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              _updateAssistantMessage(fullResponse);
              break;

            case AiEventType.error:
              _updateAssistantMessage(
                event.error?.contains('400') == true
                    ? '抱歉，该模型暂不支持图片识别'
                    : event.error?.contains('401') == true
                    ? 'API 密钥无效或已过期，请在设置中更新'
                    : '抱歉，我遇到了一点问题，请再试一次',
              );
              _finalizeStreamMessage();
              fullResponse = 'done';
              break;
          }
        }
      } catch (e) {
        _updateAssistantMessage('发送消息失败: $e');
      }

      if (fullResponse != null) break;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    _scrollToBottom();
    _saveConversation();
  }

  /// ⚠️ 一律 `jsonEncode`，不要用 `.toString()`。
  ///
  /// 工具返回的是 Map，`Map.toString()` 出来是 Dart 格式
  /// （`{success: true, query: 余耕 金枝玉叶 小说}`）——**键和字符串值都没有
  /// 引号，不是合法 JSON**。这个字符串有两个下游：
  ///
  /// 1. 发回给模型当工具结果 → 模型只能连蒙带猜地读
  /// 2. 界面拿去 `jsonDecode` → 解析失败 → **每一次调用都被标成 failed**
  ///
  /// 主 App 的 `chat_screen` 早就改过了，这一份漏了。2026-09-07 的症状是
  /// 《金枝玉叶》那场里 `Web search · 2x · 2 failed`，展开却写着 `success: true`——
  /// 我照着那个红字判断它在瞎编，结果冤枉了它。
  Future<String> _executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    final executor =
        mcpServer.registeredTools
            .where((r) => r.tool.name == tc.name)
            .firstOrNull
            ?.executor;
    if (executor != null) {
      return _encodeToolResult(() => executor(tc.arguments), tc.name);
    }

    for (final client in context.read<ExternalMcpProvider>().clients) {
      if (client.tools.any((t) => t.name == tc.name)) {
        return _encodeToolResult(
          () => client.callTool(tc.name, tc.arguments),
          tc.name,
        );
      }
    }

    return jsonEncode({'success': false, 'error': '工具 ${tc.name} 未找到'});
  }

  /// 成功失败都返回 JSON。
  ///
  /// 失败路径也必须是 JSON：模型和界面都按 JSON 读，混进裸字符串
  /// （`'错误: ...'`）会让两边都拿不到结构化的失败原因。
  Future<String> _encodeToolResult(
    Future<dynamic> Function() run,
    String name,
  ) async {
    try {
      return jsonEncode(await run());
    } catch (e) {
      return jsonEncode({'success': false, 'error': '$name 执行失败: $e'});
    }
  }

  /// [thinking] 传 null = 「这次没有新的思考」，不是「清掉已有的」。
  /// 正文每来一个 token 就重建一次这条消息，不保留的话思考会被冲掉。
  void _updateAssistantMessage(
    String content, {
    List<ToolCallInfo>? toolCalls,
    String? thinking,
  }) {
    setState(() {
      if (_conversation.messages.isNotEmpty &&
          _conversation.messages.last.role == MessageRole.assistant &&
          _conversation.messages.last.id.startsWith('stream_')) {
        _conversation.messages.last = ChatMessage(
          id: _conversation.messages.last.id,
          role: MessageRole.assistant,
          content: content,
          toolCalls: toolCalls,
          thinking: thinking ?? _conversation.messages.last.thinking,
        );
      } else {
        _conversation.messages.add(
          ChatMessage(
            id: 'stream_${_uuid.v4()}',
            role: MessageRole.assistant,
            content: content,
            toolCalls: toolCalls,
            thinking: thinking,
          ),
        );
      }
    });
    _scrollToBottom();
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
    if (_conversation.messages.isEmpty) {
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
        ).showSnackBar(const SnackBar(content: Text('Discussion 笔记已生成')));
      }
    }
  }

  void _finalizeStreamMessage() {
    setState(() {
      if (_conversation.messages.isNotEmpty &&
          _conversation.messages.last.role == MessageRole.assistant &&
          _conversation.messages.last.id.startsWith('stream_')) {
        final old = _conversation.messages.last;
        _conversation.messages.last = ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content: old.content,
          toolCalls: old.toolCalls,
          thinking: old.thinking,
        );
      }
    });
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
                  _conversation.systemPrompt = _systemPrompt;
                });
                _saveConversation();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('已同步 ${traces.highlightTotal} 条划线'),
                  ),
                );
              } else if (v == 'export') {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatExportScreen(
                      messages: _conversation.messages,
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
                  final dir = await _bookConvDir;
                  final file = File('${dir.path}/book_${widget.bookId}.json');
                  await file.delete();
                  if (mounted) {
                    _conversation.messages.clear();
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
              _isLoading
                  ? const LinearProgressIndicator()
                  : const SizedBox.shrink(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child:
                _conversation.messages.isEmpty
                    ? _buildEmptyState(theme)
                    : Builder(
                      builder: (context) {
                        // 读书版不拆气泡，理由见 groupChatItems 的注释。
                        final items = groupChatItems(
                          _conversation.messages,
                          splitBubbles: false,
                        );
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(12),
                          itemCount: items.length,
                          itemBuilder:
                              (context, index) => chatDisplayItem(
                                items,
                                index,
                                conversationId: _conversation.id,
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
              controller: _textController,
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
          IconButton(
            icon: Icon(
              _isLoading
                  ? PhosphorIconsRegular.stop
                  : PhosphorIconsRegular.paperPlaneTilt,
              color: theme.colorScheme.primary,
            ),
            onPressed: _isLoading ? null : _sendMessage,
          ),
        ],
      ),
    );
  }
}
