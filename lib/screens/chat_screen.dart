import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../widgets/app_surface.dart';
import '../widgets/typing_indicator.dart';
import 'persona_screen.dart';
import '../config/app_tab.dart';
import '../services/ai_client.dart';
import '../services/app_providers.dart';
import '../config/persona.dart';
import '../services/chat_events.dart';
import '../services/mcp_server.dart';
import '../services/phone_tools/self_note_tool.dart';
import '../services/self_notes.dart';
import '../services/small_things.dart';
import '../services/storage_service.dart';
import '../services/vision_service.dart';
import '../config/settings.dart';
import '../services/tts_service.dart';
import '../services/memory_context.dart';
import '../models/musing_entry.dart';
import '../services/musing_generator.dart';
import '../services/history_compactor.dart';
import '../search/history_search_delegate.dart';
import '../search/search_result_model.dart';
import '../widgets/chat_message_item.dart';
import '../widgets/background_sheet.dart';
import '../widgets/mark_backdrop.dart';
import 'settings_screen.dart';
import 'musing_corner_screen.dart';
import 'pc_chat_screen.dart';
import '../config/app_shape.dart';

class ChatScreen extends StatefulWidget {
  /// 底部导航切换回调，用于从聊天页跳转到书架 / 工具 / 设置。
  final void Function(AppTab tab)? onSwitchTab;

  /// 聊天背景变化回调，用于通知 HomeShell 刷新全局背景。
  final VoidCallback? onBackgroundChanged;

  /// 对话模式变化回调：true=进入对话（隐藏 Tab 栏），false=回到主页。
  final ValueChanged<bool>? onChatModeChanged;

  const ChatScreen({
    super.key,
    this.onSwitchTab,
    this.onBackgroundChanged,
    this.onChatModeChanged,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final _uuid = const Uuid();
  final _picker = ImagePicker();

  /// 一条消息最多几张图。
  ///
  /// 不是产品洁癖，是报文大小：每张按 1920px 压完再 base64，一张就一两百 KB，
  /// 而且历史里每一条都要重发。六张已经是单条消息一兆上下了。
  static const _kMaxImagesPerMessage = 6;

  /// 选好但**还没发出去**的图。这是这次改动的全部要点——
  /// 以前没有这个中间状态，选完就飞出去了。
  final _pendingImages = <XFile>[];
  bool _isLoading = false;
  bool _chatMode = false;
  List<Conversation> _savedConversations = [];
  String? _musingContent;
  bool _musingFavorited = false;
  bool _musingLoading = false;
  String _userName = '';
  String _aiName = '';

  /// 抽屉右侧那几个数字。开抽屉时刷新一次，不常驻订阅。
  int _favoriteCount = 0;
  int _trashCount = 0;

  late Conversation _conversation;

  /// 存一份引用，dispose 时要用它摘监听——那时候 context 已经不能读 Provider 了。
  AiClientProvider? _aiClients;

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(id: _uuid.v4());
    _aiClients =
        context.read<AiClientProvider>()..addListener(_onAiClientChanged);
    _loadConversations();
    _loadMusing();
    _loadUserName();
    // 时间线上那几条灰字（写了信、记了日记）。附加信息，读失败也不影响聊天。
    _loadChatEvents();
  }

  Future<void> _loadUserName() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _userName = settings.userName;
      _aiName = settings.aiName;
    });
  }

  Future<void> _loadDrawerCounts() async {
    final favorites = await StorageService.listFavoritedMusings();
    final trashed = await StorageService.listTrashedConversations();
    if (!mounted) return;
    setState(() {
      _favoriteCount = favorites.length;
      _trashCount = trashed.length;
    });
  }

  /// 抽屉顶部那句「和 XX 一起，N 条消息」。
  ///
  /// 数的是 `messages.length`，即**条数**——用户和它的话都算。原来这里叫
  /// 「N 轮对话」，但一轮是一来一回，条数差着一倍；而首页的对话卡片一直
  /// 写的是「N 条消息」，同一个数在两处叫两个名字。统一成条。
  int get _totalMessages =>
      _savedConversations.fold(0, (sum, c) => sum + c.messages.length);

  @override
  void dispose() {
    _aiClients?.removeListener(_onAiClientChanged);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    final convs = await StorageService.listConversations();
    if (mounted) setState(() => _savedConversations = convs);
  }

  Future<void> _loadMusing() async {
    final cached = await StorageService.getTodayMusing();
    if (cached != null) {
      if (mounted) {
        setState(() {
          _musingContent = cached['content'] as String?;
          _musingFavorited = cached['favorited'] as bool? ?? false;
        });
      }
      return;
    }
    await _refreshMusing();
  }

  /// 在别处发生、要插进这条时间线的事（它写了信、记了日记）。
  ///
  /// 只取**这段对话开始之后**的：更早的事对这段对话没有意义，
  /// 全塞进来会在开头堆一片跟当下无关的灰条。
  List<ChatEvent> _chatEvents = const [];

  Future<void> _loadChatEvents() async {
    if (_conversation.messages.isEmpty) return;
    final since = _conversation.messages.first.timestamp;
    final events = await ChatEvents.since(since, aiName: _aiName);
    if (mounted) setState(() => _chatEvents = events);
  }

  /// 今天的「我想说」还欠着，等 AI 客户端就绪补生成。
  ///
  /// [_loadMusing] 在 initState 里调，而 `AiClientProvider.load()` 是异步的
  /// ——那一刻 `currentClient` 基本都是 null。原来这里直接 return，于是跨天
  /// 之后首页永远停在昨天那句，只能手动点刷新（用户反馈「大部分情况都得
  /// 自己刷」就是这个）。现在标记待办，由 [_onAiClientChanged] 补跑。
  bool _musingPending = false;

  void _onAiClientChanged() {
    if (!_musingPending) return;
    if (_aiClients?.currentClient == null) return;
    _musingPending = false;
    _refreshMusing();
  }

  Future<void> _refreshMusing() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) {
      _musingPending = true;
      return;
    }
    if (mounted) setState(() => _musingLoading = true);
    try {
      final content = await generateDailyMusing(aiClient: aiClient);
      if (content != null) {
        await StorageService.setTodayMusing(content);
        if (mounted) {
          setState(() {
            _musingContent = content;
            _musingFavorited = false;
          });
        }
      }
    } catch (_) {
      // 生成失败就静默保留原内容，不打扰用户
    } finally {
      if (mounted) setState(() => _musingLoading = false);
    }
  }

  Future<void> _toggleFavoriteMusing() async {
    if (_musingContent == null) return;
    final newState = !_musingFavorited;
    setState(() => _musingFavorited = newState);
    await StorageService.setTodayMusingFavorited(newState);
    if (newState) {
      await StorageService.addFavoritedMusing(
        MusingEntry(
          id: _uuid.v4(),
          date: DateTime.now(),
          content: _musingContent!,
        ),
      );
    } else {
      // 取消收藏：从收藏列表里把今天这条同内容的条目摘掉
      final favorites = await StorageService.listFavoritedMusingsForToday();
      final match =
          favorites.where((m) => m.content == _musingContent).firstOrNull;
      if (match != null) {
        await StorageService.removeFavoritedMusing(match.id);
      }
    }
  }

  void _switchConversation(Conversation conv) {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = conv;
      _isLoading = false;
      _textController.clear();
      _chatMode = true;
      // 换了对话，上一段的事件行不能留着——它们的时间落在这一段之外。
      _chatEvents = const [];
    });
    _loadChatEvents();
    widget.onChatModeChanged?.call(true);
    _scrollToBottom();
  }

  void _newConversation() {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = Conversation(id: _uuid.v4());
      _isLoading = false;
      _textController.clear();
      _chatMode = true;
    });
    widget.onChatModeChanged?.call(true);
    _loadConversations();
  }

  /// 返回主页：保存当前对话，回到主页模式。
  void _goHome() {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = Conversation(id: _uuid.v4());
      _isLoading = false;
      _chatMode = false;
      _textController.clear();
    });
    widget.onChatModeChanged?.call(false);
    _loadConversations();
  }

  void _enterChatMode() {
    if (_chatMode) return;
    setState(() => _chatMode = true);
    widget.onChatModeChanged?.call(true);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        // Try again after layout settles
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    });
  }

  void _openSearch() async {
    final result = await showSearch<HistorySearchSelection?>(
      context: context,
      delegate: HistorySearchDelegate(_savedConversations),
    );
    if (result != null && mounted) {
      _switchToSearchResult(result);
    }
  }

  void _switchToSearchResult(HistorySearchSelection selection) {
    _switchConversation(selection.conversation);
    if (selection.scrollToMessageIndex != null) {
      _scrollToMessage(selection.scrollToMessageIndex!);
    }
  }

  void _scrollToMessage(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      // Estimate: each message roughly 100px, tool cards ~80px
      double offset = 0;
      for (int i = 0; i < index && i < _conversation.messages.length; i++) {
        final msg = _conversation.messages[i];
        if (msg.role == MessageRole.toolCall && msg.toolCalls != null) {
          offset += 80;
        } else {
          offset += 100;
        }
      }
      final maxScroll = _scrollController.position.maxScrollExtent;
      _scrollController.animateTo(
        offset.clamp(0.0, maxScroll),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// 选图**只放进待发区，不发出去**。
  ///
  /// 原来这个函数叫 `_pickAndSendImage`：选完立刻调识图、拼消息、`_continueChat()`，
  /// 中间没有任何一处可以反悔或者补一句话。从相册点一张图，它就已经飞出去了
  /// ——这不是发消息该有的节奏，而且它绕开了 `_sendMessage`，
  /// 于是「空文本不发送」那条判断从来没在这条路上生效过。
  ///
  /// 拍照仍然是单张（相机一次就拍一张），相册用 `pickMultiImage`。
  Future<void> _pickImages(ImageSource source) async {
    final picked = <XFile>[];
    if (source == ImageSource.camera) {
      final shot = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
      );
      if (shot != null) picked.add(shot);
    } else {
      picked.addAll(
        await _picker.pickMultiImage(maxWidth: 1920, maxHeight: 1920),
      );
    }
    if (picked.isEmpty || !mounted) return;

    final room = _kMaxImagesPerMessage - _pendingImages.length;
    _enterChatMode();
    setState(() => _pendingImages.addAll(picked.take(room)));

    // 超出的**明说**，别默默吞掉——用户选了八张只看到六张，
    // 不告诉他就成了「这 App 有时候会丢图」。
    if (picked.length > room) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '一条消息最多 $_kMaxImagesPerMessage 张，多出的 ${picked.length - room} 张没有加进来',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        ctx,
                      ).colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.camera,
                        '拍照',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickImages(ImageSource.camera),
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.images,
                        '相册',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickImages(ImageSource.gallery),
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.fileText,
                        '文件',
                        () => Navigator.of(ctx).pop(),
                        action: _pickAndSendFile,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
    );
  }

  Widget _attachmentItem(
    BuildContext ctx,
    IconData icon,
    String label,
    VoidCallback onClose, {
    required VoidCallback action,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () {
          onClose();
          action();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.outline.withValues(alpha: 0.2),
                  ),
                ),
                child: Icon(icon, size: 24, color: scheme.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: scheme.onSurface),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      _enterChatMode();
      final file = result.files.single;
      final name = file.name;
      var content = '';
      final path = file.path;
      if (path != null) {
        final f = File(path);
        if (await f.exists() && await f.length() < 200 * 1024) {
          try {
            final bytes = await f.readAsBytes();
            content = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {}
        }
      }
      final trimmed = content.trim();
      final msgText =
          trimmed.isNotEmpty
              ? '📎 文件：$name\n\n${trimmed.length > 2000 ? trimmed.substring(0, 2000) : trimmed}'
              : '📎 文件：$name（${file.size} 字节，非文本内容，已附带文件名）';

      final userMsg = ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.user,
        content: msgText,
      );
      setState(() {
        _conversation.messages.add(userMsg);
        _isLoading = true;
      });
      _scrollToBottom();
      _continueChat();
    } catch (_) {}
  }

  /// 「正在输入」只在**还没吐出第一个字**时显示。
  ///
  /// 流式消息的 id 以 `stream_` 开头（见 [_updateAssistantMessage]）。一旦它
  /// 有了内容，回复本身就在屏幕上了，再挂一个「正在输入」是同一件事说两遍，
  /// 而且它就悬在正在生长的那段字下面，很吵。
  ///
  /// 工具轮次里最后一条是 toolResult，这时仍然显示——那会儿它确实还没开口。
  bool get _showTyping {
    if (!_isLoading) return false;
    final messages = _conversation.messages;
    if (messages.isEmpty) return true;
    final last = messages.last;
    return !(last.role == MessageRole.assistant &&
        last.id.startsWith('stream_') &&
        last.content.isNotEmpty);
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    // **只有图、一个字都没打，也是一条完整的消息**——用户就是想给它看一眼。
    // 原来这里是 `text.isEmpty` 直接 return，而选图那条路自己绕开了
    // _sendMessage，所以这条判断在图片上从来没生效过。
    if ((text.isEmpty && _pendingImages.isEmpty) || _isLoading) return;

    // context 要在 await 之前用掉，别跨异步边界再摸它。
    final client = context.read<AiClientProvider>().currentClient;

    HapticFeedback.lightImpact();
    _enterChatMode();
    _textController.clear();

    final picked = List<XFile>.from(_pendingImages);
    setState(() => _pendingImages.clear());

    final images = <String>[];
    for (final file in picked) {
      images.add(base64Encode(await file.readAsBytes()));
    }

    // 识图服务是**兜底**，不是主路。
    //
    // 模型自己能看图的时候（sendsImagesNatively），原图会随报文一起发过去，
    // 再调一次外部识图就是同一张图分析两遍、付两份钱，而且模型会同时收到
    // 图和一段别人写的描述——描述和它自己看到的不一致时，它信哪个都不对。
    //
    // 只有模型看不到图时才退回来换一段文字。没配 key 的话 analyze 直接返回
    // null，这里也就是几次空转。
    var content = text;
    if (images.isNotEmpty && client != null && !client.sendsImagesNatively) {
      final described = <String>[];
      for (final image in images) {
        final result = await VisionService.analyze(
          image,
          prompt: text.isNotEmpty ? text : null,
        );
        if (result != null) described.add(result);
      }
      if (described.isNotEmpty) {
        content =
            '${text.isNotEmpty ? '$text\n\n' : ''}'
            '[图片分析: ${described.join('；')}]';
      }
    }

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: content,
      images: images,
    );

    if (!mounted) return;
    setState(() {
      _conversation.messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();
    _continueChat();
  }

  Future<void> _continueChat() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;

    if (aiClient == null) {
      setState(() {
        _conversation.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: '⚠️ 请先在设置中配置 API Key',
          ),
        );
        _isLoading = false;
      });
      return;
    }

    // 便签工具要知道自己身处哪段对话，才能把「做好了吗」推回原地。
    // 工具执行器的签名只有 args，拿不到调用现场，所以在这儿放一次。
    SelfNoteTool.currentConversationId = _conversation.id;

    // Build client with tools once, reuse for all rounds
    // Always include local phone tools (regardless of MCP Server toggle)
    final mcpTools = mcpServer.registeredTools.map((r) => r.tool).toList();
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;
    final allTools = [...mcpTools, ...externalTools];
    final clientWithTools = AiClient(config: aiClient.config, tools: allTools);

    // 身份（名字 + 性格）抽到了 config/persona.dart：主动说话那条路要用
    // **同一份**，否则它开口时不是它。三层优先级和取名字的理由都写在那儿。
    //
    // 传 fallback 是因为 AppSettings.load() 里那句读 keystore 没有 try/catch，
    // 出问题会整个抛。这条路在发消息的主路上，不能为了一个名字把消息卡住——
    // initState 拿到的那份旧一点，但有。
    final identity = await buildIdentityPrompt(
      conversationPersona: _conversation.systemPrompt,
      fallbackAiName: _aiName,
      fallbackUserName: _userName,
    );

    // 人设和记忆分开传，别在这儿拼成一个字符串。
    //
    // 人设长期不变、记忆几乎天天变，拼在一起会让整个 system 块每天都变一次；
    // 而它排在最前面，一变就把后面几千 token 的对话历史全部挤出 prompt 缓存。
    // ai_client 会把记忆挂到最后一条用户消息上，详见 _attachMemory。
    final memoryContext = await buildMemoryContext();

    // 长期记忆的摘要层进 system 块，**不进 memoryContext**。
    //
    // 那两块的去处是不一样的：memoryContext 天天变，挂在最后一条用户消息
    // 尾部；这一块几乎不变，跟人设一起待在前缀里吃 KV 缓存。详见
    // buildMemoryDigest 的注释。
    //
    // 排在人设和规则之后：那两段是 const，最不变；摘要偶尔会改，
    // 排在它们后面，改一次不至于把前面那两段也一起失效。
    //
    // 同样兜异常——它只是「知道得多一点」，读不出来就当没有，
    // 不能因为它把消息卡住。
    var digest = '';
    try {
      digest = await buildMemoryDigest();
    } catch (e) {
      debugPrint('[chat] 读长期记忆失败，这次不带：$e');
    }

    // 顺序是按「多久变一次」排的，越不变的越靠前。前缀命中缓存是逐字节从头
    // 比对的，把易变的放前面会把后面整段一起作废。
    //
    // 身份（名字 + 人设，几乎不变）→ 读记录的规则（const）→ 写记忆的规矩
    // （const）→ 记忆摘要（记忆改了才变）。近期记录不在这儿：它天天变，
    // 挂在最后一条用户消息尾部。
    //
    // 写记忆的规矩紧跟读记忆的，中间不夹会变的东西；摘要排在它俩后面——
    // 「先看已有的那几条」指的就是它。
    //
    // 两段规矩都在身份外面：自定义了性格的对话会整段替掉人设，
    // 记不记东西、怎么读记录，不该被「用什么口吻说话」连坐。
    final systemPrompt = [
      identity,
      memoryReadingRules,
      memoryWritingRules,
      selfNoteRules,
      smallThingRules,
      if (digest.isNotEmpty) digest,
    ].join('\n\n');

    // 聊得够久了就把早期消息折成摘要。
    //
    // 用不带工具的 aiClient：摘要任务不需要工具，带上只会多烧 token，还可能
    // 让模型在整理记录时莫名其妙去调用工具。
    if (needsCompaction(_conversation)) {
      final compacted = await compactHistory(
        conv: _conversation,
        aiClient: aiClient,
      );
      if (compacted) _saveConversation();
    }

    // Loop: keep calling AI and executing tools until AI responds with text
    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;

      String? fullResponse;
      // 思考单独攒。它不进 fullResponse——那个要发回给服务端当上文。
      String? thinkingBuffer;

      try {
        // 切片放在循环里算，不能提到外面：工具轮次会往 messages 末尾追加，
        // 提到外面就是个过期快照，后面几轮发出去的历史会缺东西。
        await for (final event in clientWithTools.chat(
          _visibleHistory(),
          systemPrompt: systemPrompt,
          memoryContext: memoryContext,
          historySummary: _conversation.summary,
        )) {
          switch (event.type) {
            case AiEventType.thinking:
              // 思考先到、正文还没开始，所以这里 fullResponse 通常还是 null：
              // 传空串让气泡先立起来，人就能看见它在想，而不是干等。
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
              fullResponse = fullResponse ?? '';
              // Embed tool calls in the assistant message, then finalize
              _updateAssistantMessage(
                fullResponse,
                toolCalls: event.toolCalls ?? [],
              );
              _finalizeStreamMessage();
              for (final tc in event.toolCalls ?? []) {
                String toolResult;
                try {
                  toolResult = await _executeTool(mcpServer, tc);
                } catch (e) {
                  // 无论工具执行内部出什么问题，都必须给这个 tool_call_id
                  // 留一条结果消息——不然对话历史会永久损坏（AI 服务商的
                  // API 要求每个 tool_calls 都必须有对应的响应，缺一个就会
                  // 一直 400，且没法靠重试恢复，因为坏掉的历史已经存下来了）
                  toolResult = jsonEncode({
                    'success': false,
                    'error': '工具执行异常: $e',
                  });
                }
                _conversation.messages.add(
                  ChatMessage(
                    id: _uuid.v4(),
                    role: MessageRole.toolResult,
                    content: toolResult,
                    toolCallId: tc.id,
                  ),
                );
              }
              // Break out of the stream loop to continue the outer while loop
              fullResponse = null; // signal that we need another round
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              _updateAssistantMessage(fullResponse);
              break;

            case AiEventType.error:
              debugPrint('[chat] AI error: ${event.error}');
              _updateAssistantMessage('⚠️ 错误: ${event.error ?? "未知"}');
              _finalizeStreamMessage();
              fullResponse = 'done';
              break;
          }
        }
      } catch (e) {
        _updateAssistantMessage('❌ 发送消息失败: $e');
      }

      // 可选：自动朗读 AI 回复
      if (fullResponse != null && fullResponse.isNotEmpty && mounted) {
        final last =
            _conversation.messages.isNotEmpty
                ? _conversation.messages.last
                : null;
        if (last != null &&
            last.role == MessageRole.assistant &&
            last.content.trim().isNotEmpty) {
          try {
            // 先把 service 取出来再 await：await 之后这个 State 可能已经销毁，
            // 那时再碰 context 就是 use_build_context_synchronously 说的那种崩法。
            final tts = context.read<TtsService>();
            final settings = await AppSettings.load();
            if (settings.ttsAutoPlay) {
              await tts.toggle(last.id, last.content);
            }
          } catch (_) {
            // 自动朗读失败不影响聊天
          }
        }
      }

      // If there was a tool call, the loop continues
      // If there was an error or done with text, exit
      if (fullResponse != null) break;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    _scrollToBottom();
    _saveConversation();
  }

  /// 去掉已被摘要覆盖的那段，只发剩下的原文。
  List<ChatMessage> _visibleHistory() {
    final n = _conversation.summarizedCount;
    if (n <= 0 || n >= _conversation.messages.length) {
      return _conversation.messages;
    }
    return _conversation.messages.sublist(n);
  }

  static const _toolTimeout = Duration(seconds: 60);

  Future<String> _executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    final extProvider = context.read<ExternalMcpProvider>();

    // Try local MCP server first
    final executor =
        mcpServer.registeredTools
            .where((r) => r.tool.name == tc.name)
            .firstOrNull
            ?.executor;
    // 一律 jsonEncode，不要用 .toString()。
    //
    // 工具返回的是 Map，Map.toString() 出来是 Dart 格式（`{success: true, ...}`）——
    // 键和字符串值都没有引号，不是合法 JSON。这个字符串既发回给模型（于是模型
    // 从来没真正读到过工具结果），又被界面拿去 jsonDecode（于是每次都解析失败、
    // 显示「未成功」且展开空白）。
    if (executor != null) {
      return _runToolWithTimeout(
        () async => jsonEncode(await executor(tc.arguments)),
        tc.name,
      );
    }

    // Try external MCP servers
    for (final client in extProvider.clients) {
      if (client.tools.any((t) => t.name == tc.name)) {
        return _runToolWithTimeout(
          () async => jsonEncode(await client.callTool(tc.name, tc.arguments)),
          tc.name,
        );
      }
    }

    return jsonEncode({'success': false, 'error': '工具 ${tc.name} 未找到'});
  }

  /// 工具执行统一加超时并吞掉异常：无论成功/超时/失败都返回字符串结果，
  /// 避免 assistant(tool_calls) 成为“孤儿”导致下次发送报 invalid_request_error。
  Future<String> _runToolWithTimeout(
    Future<String> Function() run,
    String toolName,
  ) async {
    // 失败路径同样返回 JSON：模型和界面都按 JSON 解析，
    // 混进裸字符串会让两边都拿不到结构化的失败原因。
    try {
      return await run().timeout(
        _toolTimeout,
        onTimeout:
            () => jsonEncode({
              'success': false,
              'error': '工具 $toolName 执行超时（${_toolTimeout.inSeconds} 秒），请重试',
            }),
      );
    } catch (e) {
      return jsonEncode({'success': false, 'error': '工具 $toolName 执行失败: $e'});
    }
  }

  /// [thinking] 传 null 表示「这次没有新的思考」，不是「把已有的清掉」——
  /// 正文每来一个 token 就重建一次这条消息，不保留的话思考会被后面的正文冲掉。
  void _updateAssistantMessage(
    String content, {
    List<ToolCallInfo>? toolCalls,
    String? thinking,
  }) {
    // 过滤模型可能复读出来的 [time: ...] 标记（系统注入的时间戳元数据）
    final cleaned =
        content
            .replaceAll(RegExp(r'\[time:[^\]]*\]'), '')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trimLeft();
    setState(() {
      if (_conversation.messages.isNotEmpty &&
          _conversation.messages.last.role == MessageRole.assistant &&
          _conversation.messages.last.id.startsWith('stream_')) {
        _conversation.messages.last = ChatMessage(
          id: _conversation.messages.last.id,
          role: MessageRole.assistant,
          content: cleaned,
          toolCalls: toolCalls,
          thinking: thinking ?? _conversation.messages.last.thinking,
        );
      } else {
        _conversation.messages.add(
          ChatMessage(
            id: 'stream_${_uuid.v4()}',
            role: MessageRole.assistant,
            content: cleaned,
            toolCalls: toolCalls,
            thinking: thinking,
          ),
        );
      }
    });
    _scrollToBottom();
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

  void _showConversationList() {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Text(
                        '对话历史',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(PhosphorIconsRegular.plus, size: 18),
                        label: const Text('新建'),
                        onPressed: () => _newConversation(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                InkWell(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _openSearch();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          PhosphorIconsRegular.magnifyingGlass,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '搜索历史对话',
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child:
                      _savedConversations.isEmpty
                          ? const Center(child: Text('暂无历史对话'))
                          : ListView.builder(
                            itemCount: _savedConversations.length,
                            itemBuilder: (ctx, i) {
                              final conv = _savedConversations[i];
                              final isCurrent = conv.id == _conversation.id;
                              return ListTile(
                                title: Text(
                                  conv.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${conv.messages.length} 条消息 · ${conv.model}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                selected: isCurrent,
                                trailing: IconButton(
                                  icon: const Icon(
                                    PhosphorIconsRegular.trash,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    await StorageService.deleteConversation(
                                      conv.id,
                                    );
                                    _loadConversations();
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                  },
                                ),
                                onTap: () => _switchConversation(conv),
                              );
                            },
                          ),
                ),
              ],
            ),
          ),
    ).then((_) => _loadConversations());
  }

  void _showRenameDialog() {
    final controller = TextEditingController(text: _conversation.title);
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名对话'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入对话名称',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _conversation.title = controller.text.trim();
                    _conversation.titleManuallySet = true;
                  });
                  _saveConversation();
                  Navigator.of(ctx).pop();
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  void _showRenameConversationDialog(Conversation conv) {
    final controller = TextEditingController(text: conv.title);
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('重命名对话'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '输入对话名称',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final title = controller.text.trim();
                  if (title.isNotEmpty) {
                    conv.title = title;
                    conv.titleManuallySet = true;
                    StorageService.saveConversation(conv);
                  }
                  Navigator.of(ctx).pop();
                  _loadConversations();
                },
                child: const Text('确定'),
              ),
            ],
          ),
    );
  }

  /// 编这段对话自己的性格。
  ///
  /// 这个入口在 4c2fd85（全局改版）里被删掉了，但 `Conversation.systemPrompt`
  /// 的字段、JSON 读写、读取路径一直都在——只是没地方设置。这次是把入口补回来。
  ///
  /// ⚠️ 旧版那个对话框改完 `_conversation.systemPrompt` **没有调
  /// `_saveConversation()`**，退出去可能就没了。这次补上。
  Future<void> _editPersona() async {
    // 只是为了判断「全局那边空不空」，读不出来就当空的——
    // 最坏后果是多问一次，不该因此打不开编辑页。
    var globalPersona = '';
    try {
      globalPersona = (await AppSettings.load()).persona.trim();
    } catch (e) {
      debugPrint('[chat] 读全局性格失败，按空的算：$e');
    }
    if (!mounted) return;

    final result = await Navigator.of(context).push<PersonaResult>(
      MaterialPageRoute(
        builder:
            (_) => PersonaScreen(
              initial: _conversation.systemPrompt ?? '',
              globalIsEmpty: globalPersona.isEmpty,
            ),
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      // 空串存成 null，不存空字符串：null 才是「没设过，用默认」，
      // 空串会被上面那个 ?? 当成「设过了，就是空的」，于是人设整个消失。
      _conversation.systemPrompt = result.text.isEmpty ? null : result.text;
    });
    _saveConversation();

    if (result.alsoGlobal) {
      try {
        final settings = await AppSettings.load();
        settings.persona = result.text;
        // 用户刚说了「用在所有对话」，那就得真的生效——存了文本却不开开关，
        // 等于什么都没发生，而他不会知道为什么。
        settings.personaEnabled = true;
        await settings.save();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('这段对话存好了，但没能存进全局：$e')));
      }
    }
  }

  Future<void> _exportConversation() async {
    if (_conversation.messages.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有消息可以导出')));
      return;
    }
    try {
      final buffer = StringBuffer();
      buffer.writeln('📱 手机 AI 助手 - 对话导出');
      buffer.writeln('标题: ${_conversation.title}');
      buffer.writeln('时间: ${DateTime.now().toLocal().toString()}');
      buffer.writeln('=' * 40);
      buffer.writeln('');

      for (final msg in _conversation.messages) {
        String role;
        switch (msg.role) {
          case MessageRole.user:
            role = '👤 你';
          case MessageRole.assistant:
            role = '🤖 AI';
          case MessageRole.toolCall:
            role = '🛠 工具';
          case MessageRole.toolResult:
            role = '📋 结果';
          default:
            role = '📝 系统';
        }
        buffer.writeln('$role: ${msg.content}');
        if (msg.images.isNotEmpty) {
          buffer.writeln('  [图片附件 × ${msg.images.length}]');
        }
        buffer.writeln('');
      }

      // Save to temp file and share
      final dir = await getTemporaryDirectory();
      final fileName =
          '对话_${_conversation.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(buffer.toString());

      await Share.shareXFiles([
        XFile(file.path),
      ], text: '📱 手机 AI 助手 - ${_conversation.title}');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    }
  }

  void _saveConversation() {
    if (!_conversation.titleManuallySet) {
      // content 本身不可空，所以后面那个 `?.` 是无效的。顺手把空内容也归到
      // 「新对话」：原来第一条消息是空串时，substring(0,0) 会把标题存成空字符串。
      final first = _conversation.messages.firstOrNull?.content;
      _conversation.title =
          (first == null || first.isEmpty)
              ? '新对话'
              : first.substring(0, first.length.clamp(0, 30));
    }
    StorageService.saveConversation(_conversation);
  }

  /// 三宫格。图标二选一：品牌图标给 [asset]，功能图标给 [icon]——
  /// 星=新对话、书=书架属于「地方和内容」，显示器属于「机器」，各归各的。
  Widget _quickActionCard(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String label,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    return Expanded(
      // 阴影画在 Material 外面：Material 的 elevation 出来偏灰，
      // AppSurface 负责底（玻璃或实心），Material 透明浮在上面只管水波纹。
      // 不能反过来让 Material 上色——那会盖掉玻璃。
      child: AppSurface(
        borderRadius: AppRadius.mdAll,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color:
                          primary
                              ? scheme.primary.withValues(alpha: 0.11)
                              : scheme.onSurface.withValues(alpha: 0.055),
                      shape: BoxShape.circle,
                    ),
                    child:
                        asset != null
                            ? Image.asset(
                              'assets/icons/$asset.png',
                              height: asset == 'books' ? 15 : 16,
                              color:
                                  primary
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                            )
                            : Icon(
                              icon,
                              size: 18,
                              color: scheme.onSurfaceVariant,
                            ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;

    return PopScope(
      canPop: !_chatMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _chatMode) _goHome();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        drawer: _buildDrawer(theme),
        onDrawerChanged: (open) {
          if (open) _loadDrawerCounts();
        },
        drawerEnableOpenDragGesture: !_chatMode,
        drawerEdgeDragWidth: 48,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: fgColor,
          toolbarHeight: _chatMode ? null : 64,
          leading: Builder(
            builder:
                (ctx) =>
                    _chatMode
                        ? _topBarIcon(
                          PhosphorIconsRegular.arrowLeft,
                          onPressed: _goHome,
                          tooltip: '返回主页',
                          color: fgColor,
                        )
                        : _topBarIcon(
                          PhosphorIconsRegular.list,
                          onPressed: () => Scaffold.of(ctx).openDrawer(),
                          tooltip: '菜单',
                          color: fgColor,
                        ),
          ),
          title:
              !_chatMode
                  ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Consumer<SettingsProvider>(
                        builder: (context, sp, _) {
                          final serif = sp.settings?.titleSerif ?? true;
                          return Text(
                            _greeting(),
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontFamily: serif ? 'NotoSerifSC' : null,
                              fontWeight: FontWeight.w700,
                              color: fgColor,
                            ),
                          );
                        },
                      ),
                      Text(
                        _homeDateStr(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fgColor.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  )
                  : (_conversation.messages.isNotEmpty
                      ? _chatTitle(theme, fgColor)
                      : null),
          actions: [
            _topBarIcon(
              PhosphorIconsRegular.magnifyingGlass,
              onPressed: _openSearch,
              tooltip: '搜索',
              color: fgColor,
            ),
            // 对话模式下汉堡被返回键顶掉了，抽屉只能靠边缘滑——
            // 「重命名 / 导出」这两个动作等于藏起来了。给它们一个明面入口。
            if (_chatMode)
              PopupMenuButton<String>(
                icon: Icon(PhosphorIconsRegular.dotsThree, color: fgColor),
                tooltip: '更多',
                onSelected: (v) {
                  if (v == 'rename') _showRenameDialog();
                  if (v == 'persona') _editPersona();
                  if (v == 'export') _exportConversation();
                },
                itemBuilder:
                    (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'persona', child: Text('TA 的性格')),
                      PopupMenuItem(value: 'export', child: Text('导出聊天')),
                    ],
              ),
          ],
        ),
        body: Column(
          children: [
            // 内容区：主页模式显示首页，对话模式显示消息
            Expanded(
              child:
                  _chatMode
                      ? (_conversation.messages.isEmpty
                          ? _buildEmptyChatHint(theme)
                          : Builder(
                            builder: (context) {
                              // 连续的工具消息折成一组，不能在 itemBuilder 里
                              // 逐条判断——单条消息看不出后面还有没有
                              final items = groupChatItems(
                                _conversation.messages,
                                events: _chatEvents,
                              );
                              final typing = _showTyping;
                              return MarkBackdrop(
                                child: ListView.builder(
                                  controller: _scrollController,
                                  padding: const EdgeInsets.all(12),
                                  itemCount: items.length + (typing ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    // 「正在输入」挂在最后一项：回复将来落在
                                    // 哪儿，它就等在哪儿。
                                    if (typing && index == items.length) {
                                      return TypingIndicator(name: _aiName);
                                    }
                                    return chatDisplayItem(
                                      items,
                                      index,
                                      conversationId: _conversation.id,
                                    );
                                  },
                                ),
                              );
                            },
                          ))
                      : _buildHome(theme),
            ),

            // 输入区只在对话模式出现。
            //
            // 主页原来底部同时挂着输入框和悬浮导航胶囊，两个白色悬浮元素上下
            // 叠着互相抢，底部没有唯一焦点。发消息的入口收到「新对话」和
            // 具体某段对话里去。
            if (_chatMode) _buildInputArea(theme),
          ],
        ),
      ),
    );
  }

  /// 对话页顶栏：猫底座 + 标题 + 一行状态。
  ///
  /// 「在线」不是写死的装饰——它读 `AiClientProvider.currentClient`：
  /// 为 null 就是模型没配好，这一屏根本发不出去。密钥过期时
  /// 这里会先变成「未配置模型」，比发出去之后报错早一步。
  Widget _chatTitle(ThemeData theme, Color fgColor) {
    final scheme = theme.colorScheme;
    final online = context.watch<AiClientProvider>().currentClient != null;
    final count = _conversation.messages.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Image.asset(
            'assets/icons/cat.png',
            height: 17,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
              Text(
                online ? '在线 · $count 条' : '未配置模型 · $count 条',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: online ? fgColor.withValues(alpha: 0.6) : scheme.error,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _topBarIcon(
    IconData icon, {
    required VoidCallback onPressed,
    String? tooltip,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(
        icon,
        color: color,
        shadows: const [
          Shadow(color: Color(0x66000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      onPressed: onPressed,
      tooltip: tooltip,
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    String part;
    if (hour < 5) {
      part = '夜深了';
    } else if (hour < 9) {
      part = '早上好';
    } else if (hour < 12) {
      part = '上午好';
    } else if (hour < 14) {
      part = '中午好';
    } else if (hour < 18) {
      part = '下午好';
    } else if (hour < 23) {
      part = '晚上好';
    } else {
      part = '夜深了';
    }
    return _userName.trim().isEmpty ? part : '$part，$_userName';
  }

  String _homeDateStr() {
    final today = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${today.month}月${today.day}日 · ${weekdays[today.weekday - 1]}';
  }

  Widget _buildDrawer(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final who = _userName.trim().isEmpty ? 'Cleo' : _userName.trim();
    final ta = _aiName.trim().isEmpty ? 'TA' : _aiName.trim();

    return Drawer(
      width: 296,
      // 实底：半透明会让背后花花绿绿的内容透上来，压低菜单文字的可读性
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(26),
          bottomRight: Radius.circular(26),
        ),
      ),
      child: SafeArea(
        child: Column(
          // 默认是 center：底部寄语那块比较窄，不拉满就会被居中，
          // 和上面所有左对齐的东西错开
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 身份区：打开抽屉第一眼应该知道这是谁的地方
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Row(
                children: [
                  Image.asset(
                    'assets/mark-simple.png',
                    width: 46,
                    color: dark ? scheme.onSurface : scheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'NotoSerifSC',
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '和$ta一起，$_totalMessages 条消息',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                children: [
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      asset: 'star',
                      label: '新对话',
                      primary: true,
                      onTap: () {
                        Navigator.of(context).pop();
                        _newConversation();
                      },
                    ),
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.clockCounterClockwise,
                      label: '对话历史',
                      trailing: '${_savedConversations.length}',
                      onTap: () {
                        Navigator.of(context).pop();
                        _showConversationList();
                      },
                    ),
                    _drawerItem(
                      theme,
                      asset: 'flower',
                      label: '收藏的话',
                      trailing: '$_favoriteCount',
                      onTap: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const MusingCornerScreen(),
                          ),
                        );
                      },
                    ),
                  ]),
                  // 「书架」不放这里：底部导航已经有了，同一个目的地两个入口
                  // 只会让人多想一秒。「工具」是诊断页，收在设置里。
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      asset: 'waves',
                      label: '聊天背景',
                      onTap: () {
                        Navigator.of(context).pop();
                        _openBackgroundSheet();
                      },
                    ),
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.gear,
                      label: '设置',
                      onTap: () async {
                        Navigator.of(context).pop();
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                        _loadUserName();
                      },
                    ),
                  ]),
                  _drawerGroup(theme, [
                    _drawerItem(
                      theme,
                      icon: PhosphorIconsRegular.trashSimple,
                      label: '回收站',
                      trailing: _trashCount == 0 ? null : '$_trashCount',
                      onTap: () {
                        Navigator.of(context).pop();
                        _showTrashSheet();
                      },
                    ),
                  ]),
                ],
              ),
            ),
            // 下半部分本来是大片空白。空白不是靠加功能填，是靠给它一个收尾。
            Padding(
              // 左边距 24 = 分组卡外边距 14 + 条目内边距 10，
              // 和上面那排图标底座对齐
              padding: const EdgeInsets.fromLTRB(24, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Opacity(
                    opacity: 0.3,
                    child: Image.asset(
                      'assets/icons/paw.png',
                      height: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '愿你在所有的奔波里，\n都有一个可以回来的小角落。',
                    style: TextStyle(
                      fontFamily: 'NotoSerifSC',
                      fontSize: 13,
                      height: 1.95,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerGroup(ThemeData theme, List<Widget> items) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        boxShadow: AppShadow.soften(dark),
      ),
      child: Column(children: items),
    );
  }

  Widget _drawerItem(
    ThemeData theme, {
    IconData? icon,
    String? asset,
    required String label,
    String? trailing,
    bool primary = false,
    required VoidCallback onTap,
  }) {
    final scheme = theme.colorScheme;
    final fg = primary ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    primary
                        ? scheme.primary.withValues(alpha: 0.11)
                        : scheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(10),
              ),
              child:
                  asset != null
                      ? Image.asset(
                        'assets/icons/$asset.png',
                        height: asset == 'waves' ? 13 : 16,
                        color: fg,
                      )
                      : Icon(icon, size: 16, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (trailing != null)
              Text(
                trailing,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTrashSheet() async {
    var trashed = await StorageService.listTrashedConversations();
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
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
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '回收站',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      if (trashed.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            '回收站是空的',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: trashed.length,
                            itemBuilder: (_, i) {
                              final conv = trashed[i];
                              return ListTile(
                                title: Text(
                                  conv.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${conv.messages.length} 条消息 · ${_shortTime(conv.updatedAt)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                leading: Icon(
                                  PhosphorIconsRegular.trash,
                                  color: scheme.onSurfaceVariant,
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    TextButton(
                                      onPressed: () async {
                                        await StorageService.restoreConversation(
                                          conv.id,
                                        );
                                        if (ctx.mounted) {
                                          Navigator.of(ctx).pop();
                                        }
                                        _loadConversations();
                                      },
                                      child: const Text('恢复'),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        PhosphorIconsRegular.trashSimple,
                                      ),
                                      tooltip: '彻底删除',
                                      onPressed: () async {
                                        await StorageService.permanentlyDeleteConversation(
                                          conv.id,
                                        );
                                        setSheet(
                                          () =>
                                              trashed =
                                                  trashed
                                                      .where(
                                                        (c) => c.id != conv.id,
                                                      )
                                                      .toList(),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
          ),
    );
  }

  /// 选完背景通知外层重画。真正拿路径画底的是 home_shell，
  /// 这一屏自己不持有背景状态。
  Future<void> _openBackgroundSheet() async {
    final changed = await showBackgroundSheet(context);
    if (changed && mounted) widget.onBackgroundChanged?.call();
  }

  Widget _buildEmptyChatHint(ThemeData theme) {
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            PhosphorIconsRegular.chatCircle,
            size: 56,
            color: fgColor.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          Text(
            '给 AI 发第一条消息吧',
            style: TextStyle(color: fgColor.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildHome(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      // 关掉每项的 RepaintBoundary：玻璃卡片要用 BackdropFilter 采样身后的
      // 背景图，而 RepaintBoundary 把卡片和背景隔进了两个图层，滚动时采样
      // 跟不上位移——症状是卡片「先透明一下再变模糊」。
      addRepaintBoundaries: false,
      children: [
        // 我想说
        AppSurface(
          borderRadius: AppRadius.xlAll,
          child: Stack(
            children: [
              // 右上角压一枚徽标淡印。全 App 就这里和聊天页底层两处有材质，
              // 「缺质感」补的就是这个——注意别让它吃掉点击。
              Positioned(
                top: -8,
                right: -6,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: dark ? 0.09 : 0.07,
                    child: Transform.rotate(
                      angle: -0.10472, // -6°
                      child: Image.asset(
                        'assets/mark-simple.png',
                        width: 92,
                        color:
                            dark
                                ? const Color(0xFFF2EAE0)
                                : const Color(0xFF8B5E34),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '我想说',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_musingLoading)
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: scheme.primary,
                                ),
                              )
                            else
                              Tooltip(
                                message: '戳戳ta',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.md,
                                  ),
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    _refreshMusing();
                                  },
                                  child: Icon(
                                    PhosphorIconsRegular.handTap,
                                    size: 18,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            const SizedBox(width: 10),
                            InkWell(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              onTap:
                                  _musingContent == null
                                      ? null
                                      : _toggleFavoriteMusing,
                              // 收藏是花，不是星——星归「新对话 / 进度」，
                              // 品牌图标里一个元素只认一件事。
                              //
                              // 收了是主色，没收是次级灰；两种状态必须一眼分得出，
                              // 原来两个分支是同一个 star 图标，点了看不出有没有收上。
                              child: Image.asset(
                                'assets/icons/flower.png',
                                height: 18,
                                color:
                                    _musingFavorited
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _musingContent ??
                          (_musingLoading
                              ? '在想点什么…'
                              : '开始新对话吧，我可以帮你拍照、查位置、聊书、找文件。'),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 快捷入口
        Row(
          children: [
            _quickActionCard(
              theme,
              asset: 'star',
              label: '新对话',
              primary: true,
              onTap: _newConversation,
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              asset: 'books',
              label: '书架',
              onTap: () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              icon: PhosphorIconsRegular.desktop,
              label: '电脑',
              onTap:
                  () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PcChatScreen()),
                  ),
            ),
          ],
        ),
        if (_savedConversations.isNotEmpty) ...[
          const SizedBox(height: 26),
          Row(
            children: [
              Expanded(
                child: Text(
                  '最近对话',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(PhosphorIconsRegular.trashSimple, size: 20),
                tooltip: '回收站',
                onPressed: _showTrashSheet,
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._savedConversations
              .take(20)
              .map((conv) => _conversationTile(theme, conv)),
        ],
      ],
    );
  }

  /// 会话列表项：左滑出「置顶 / 重命名 / 删除」三个操作。
  ///
  /// 原来三个动作散在三处——左滑删除、右侧图钉按钮置顶、长按重命名，得记住
  /// 哪个动作藏在哪个手势里。现在统一收进左滑面板，右侧只留一个图钉**状态**
  /// 标记（不再可点），置顶与否主要靠整行底色区分。
  Widget _conversationTile(ThemeData theme, Conversation conv) {
    final scheme = theme.colorScheme;
    final pinned = conv.isPinned;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Slidable(
          key: ValueKey('conv_${conv.id}'),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            // 三个按钮要放得下文字，比默认宽一些
            extentRatio: 0.62,
            children: [
              SlidableAction(
                onPressed: (_) async {
                  HapticFeedback.selectionClick();
                  await StorageService.setConversationPinned(conv.id, !pinned);
                  _loadConversations();
                },
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                icon:
                    pinned
                        ? PhosphorIconsFill.pushPin
                        : PhosphorIconsRegular.pushPin,
                label: pinned ? '取消置顶' : '置顶',
              ),
              SlidableAction(
                onPressed: (_) {
                  HapticFeedback.selectionClick();
                  _showRenameConversationDialog(conv);
                },
                backgroundColor: scheme.surfaceContainerHighest,
                foregroundColor: scheme.onSurface,
                icon: PhosphorIconsRegular.pencilSimple,
                label: '重命名',
              ),
              SlidableAction(
                onPressed: (_) async {
                  HapticFeedback.mediumImpact();
                  await StorageService.deleteConversation(conv.id);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('已移到回收站'),
                      behavior: SnackBarBehavior.floating,
                      action: SnackBarAction(
                        label: '撤销',
                        onPressed: () async {
                          await StorageService.restoreConversation(conv.id);
                          _loadConversations();
                        },
                      ),
                    ),
                  );
                  _loadConversations();
                },
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
                icon: PhosphorIconsRegular.trash,
                label: '删除',
              ),
            ],
          ),
          // 置顶那档的淡底跟着背景走：贴了背景图时用从图里取的色相，
          // 没有就回落到主题的 primaryContainer（徽标棕）。
          //
          // 不这么做的话，粉色背景上会冒出一块棕色的置顶卡——整屏最重的
          // 一块，比「我想说」还抢。真机上一眼就看出来了。
          child: AppSurface(
            borderRadius: AppRadius.mdAll,
            solidColor: pinned ? _pinnedTint(context, scheme) : null,
            child: Material(
              color:
                  pinned
                      ? _pinnedTint(context, scheme).withValues(alpha: 0.55)
                      : Colors.transparent,
              elevation: 0,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                title: Text(
                  conv.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color:
                        pinned ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
                subtitle: Text(
                  '${conv.messages.length} 条消息 · ${_shortTime(conv.updatedAt)}',
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        pinned
                            ? scheme.onPrimaryContainer.withValues(alpha: 0.75)
                            : scheme.onSurfaceVariant,
                  ),
                ),
                // 只做状态标记，操作都在左滑里，所以不再可点
                trailing:
                    pinned
                        ? Icon(
                          PhosphorIconsFill.pushPin,
                          size: 16,
                          color: scheme.onPrimaryContainer.withValues(
                            alpha: 0.8,
                          ),
                        )
                        : null,
                onTap: () => _switchConversation(conv),
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  _showRenameConversationDialog(conv);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 置顶卡片的淡底。贴了背景图就用从图里取的色相，否则回落到主题的
  /// primaryContainer（徽标棕）。
  ///
  /// 强调色只借背景的**色相**，饱和度和明度锁在固定档位（见
  /// `BackgroundProvider._analyze`）——这样换任何背景，它的视觉重量都一样，
  /// 不会有的图上跳出来、有的图上看不见。
  Color _pinnedTint(BuildContext context, ColorScheme scheme) {
    final accent = context.watch<BackgroundProvider>().backgroundAccent;
    if (accent == null) return scheme.primaryContainer;
    return accent.withValues(alpha: 0.22);
  }

  String _shortTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final isToday =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    if (isToday) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}/${local.day}';
  }

  Widget _buildInputArea(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_pendingImages.isNotEmpty) _pendingStrip(scheme),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: _buildTextField(theme)),
              const SizedBox(width: 8),
              // 右侧加号：拍照 / 相册 / 文件
              _circleToolButton(
                scheme,
                icon: PhosphorIconsRegular.plus,
                tooltip: '更多功能',
                onTap: _isLoading ? null : _showAttachmentMenu,
              ),
              const SizedBox(width: 6),
              // Send button
              _circleToolButton(
                scheme,
                icon:
                    _isLoading
                        ? PhosphorIconsRegular.hourglass
                        : PhosphorIconsRegular.paperPlaneTilt,
                tooltip: '发送',
                active: true,
                onTap: _isLoading ? null : _sendMessage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 待发的图，横着排在输入框上方，每张右上角一个叉。
  ///
  /// 这条要在**发送之前**看得见、去得掉。没有它，「先选后发」只是把发送延后了，
  /// 用户还是没法确认自己选了什么、选错了也撤不回来。
  Widget _pendingStrip(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _pendingImages.length,
          separatorBuilder: (_, __) => const SizedBox(width: 6),
          itemBuilder: (_, i) {
            return Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Image.file(
                    File(_pendingImages[i].path),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned(
                  top: -6,
                  right: -6,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _pendingImages.removeAt(i)),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        // 半透明压在图上，比实色圆片轻——它是个次要动作，
                        // 不该比缩略图本身还抢眼。
                        color: scheme.surface.withValues(alpha: 0.82),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: scheme.outline.withValues(alpha: 0.25),
                        ),
                      ),
                      child: Icon(
                        PhosphorIconsLight.x,
                        size: 11,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _circleToolButton(
    ColorScheme scheme, {
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            // 发送键是这一行唯一的主操作，用强调色；「+」保持中性。
            //
            // 「+」原来写死 Colors.white，深色模式下就是一颗白球——
            // 整屏最亮的东西是个次要按钮。交回给 scheme。
            color: active ? scheme.primary : scheme.surfaceContainerLow,
            shape: BoxShape.circle,
            border:
                active
                    ? null
                    : Border.all(color: scheme.outline.withValues(alpha: 0.35)),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(ThemeData theme) {
    final scheme = theme.colorScheme;
    return TextField(
      controller: _textController,
      focusNode: _focusNode,
      maxLines: 5,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: '输入消息...',
        // 输入框只靠填充色成形，不描边。
        // 之前描边 + 聚焦态的深色粗边让一个空输入框成了整屏最重的元素，
        // 而这一行里真正该被强调的是右边的发送键。键盘弹起本身已经说明了聚焦。
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide.none,
        ),
        filled: true,
        // 同上：写死的白色在深色模式下是一条亮条。
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
      ),
    );
  }
}
