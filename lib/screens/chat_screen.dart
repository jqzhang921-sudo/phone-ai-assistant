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
import '../config/app_tab.dart';
import '../services/ai_client.dart';
import '../services/app_providers.dart';
import '../services/mcp_server.dart';
import '../services/storage_service.dart';
import '../services/vision_service.dart';
import '../services/weread_service.dart';
import '../config/settings.dart';
import '../services/tts_service.dart';
import '../services/memory_context.dart';
import '../models/musing_entry.dart';
import '../services/musing_generator.dart';
import '../services/history_compactor.dart';
import '../search/history_search_delegate.dart';
import '../search/search_result_model.dart';
import '../widgets/chat_message_item.dart';
import 'settings_screen.dart';
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
  bool _isLoading = false;
  bool _chatMode = false;
  List<Conversation> _savedConversations = [];
  String? _backgroundImagePath;
  String? _musingContent;
  bool _musingFavorited = false;
  bool _musingLoading = false;
  String _userName = '';

  late Conversation _conversation;

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(id: _uuid.v4());
    _loadConversations();
    _loadBackground();
    _loadMusing();
    _loadUserName();
  }

  Future<void> _loadUserName() async {
    final settings = await AppSettings.load();
    if (mounted) setState(() => _userName = settings.userName);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConversations() async {
    final convs = await StorageService.listConversations();
    if (mounted) setState(() => _savedConversations = convs);
  }

  Future<void> _loadBackground() async {
    final path = await StorageService.getBackgroundImagePath();
    if (mounted) setState(() => _backgroundImagePath = path);
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

  Future<void> _refreshMusing() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;
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

  Future<void> _pickBackground() async {
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;
    await StorageService.setBackgroundImagePath(image.path);
    if (mounted) setState(() => _backgroundImagePath = image.path);
    widget.onBackgroundChanged?.call();
  }

  void _switchConversation(Conversation conv) {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = conv;
      _isLoading = false;
      _textController.clear();
      _chatMode = true;
    });
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

  Future<void> _pickAndSendImage(ImageSource source) async {
    final XFile? image = await _picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (image == null) return;
    _enterChatMode();
    final bytes = await image.readAsBytes();
    final base64 = base64Encode(bytes);

    final text = _textController.text.trim();
    _textController.clear();

    // Try MIMO vision analysis first
    String? visionResult;
    try {
      visionResult = await VisionService.analyze(
        base64,
        prompt: text.isNotEmpty ? text : null,
      );
    } catch (_) {}

    final content =
        visionResult != null
            ? '${text.isNotEmpty ? "$text\n\n" : ""}[图片分析: $visionResult]'
            : (text.isNotEmpty ? text : '分析这张图片');

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: content,
      imageData: base64,
    );

    setState(() {
      _conversation.messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();
    _continueChat();
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
                        action: () => _pickAndSendImage(ImageSource.camera),
                      ),
                      _attachmentItem(
                        ctx,
                        PhosphorIconsRegular.images,
                        '相册',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickAndSendImage(ImageSource.gallery),
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

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isLoading) return;
    // 空输入和发送中都已经在上面挡掉了，走到这儿才是真的发出去
    HapticFeedback.lightImpact();
    _enterChatMode();
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

    // Build client with tools once, reuse for all rounds
    // Always include local phone tools (regardless of MCP Server toggle)
    final mcpTools = mcpServer.registeredTools.map((r) => r.tool).toList();
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;
    final allTools = [...mcpTools, ...externalTools];
    final clientWithTools = AiClient(config: aiClient.config, tools: allTools);

    // 刻意不给这段关系起名字。
    //
    // 原来开头写死「你是用户的好朋友、日常小伙伴」，于是模型演的是它对「朋友」
    // 这个词的刻板印象：每句都要接个问题、不停找话题、还爱解说你们正在聊天
    // 这件事（「还是就等着我回你消息呢」）。角色标签给模型的是一个要扮演的
    // 形象，具体的行为约束给的才是怎么做。
    //
    // 而且这跟写信那边的提示词是矛盾的——那边明写了「不要预设你和 TA 是什么
    // 关系，那由你们相处的方式决定」，这边却先把人设焊死了。
    const basePersona =
        '你住在用户手机上，和 TA 长期相处。\n'
        '你们算什么关系，由相处的方式慢慢决定，不由设定决定。'
        '别自称朋友、伙伴、助手，也别给这段关系起名字。\n'
        '你记得 TA 的事，也在意 TA 过得怎么样，'
        '但这该体现在说话的分寸里，不是反复表态。\n\n'
        '说话：\n'
        '- 像发微信一样短。一句话能说完就一句话，'
        '不用每次都把背景、原因、建议交代一遍。\n'
        '- 不用每句都接一个问题。TA 说「没事」「在呢」这种，回一句就够了，'
        '不必每次都把话头递回去。停顿也是对话的一部分。\n'
        '- 少用 emoji，多数时候一个都不用。\n'
        '- 别描述你们正在聊天这件事本身，也别复述 TA 的状态'
        '（「你是不是在等我」「你今天好像有点累」这类）。想说什么直接说。\n'
        '- 少用「首先」「另外」「总的来说」这类书面转折词。\n'
        '- 不知道就说不知道，别顺着 TA 的话往下编。\n\n'
        '你能用手机上的工具帮忙：拍照、查文件、定位、查天气、找新闻、'
        '翻 TA 在微信读书的划线等等。需要时直接用，别把对话变成任务交接。\n'
        '只有内容本身复杂、或者 TA 明确要你展开时才详细讲，默认从简。';
    // 人设和记忆分开传，别在这儿拼成一个字符串。
    //
    // 人设长期不变、记忆几乎天天变，拼在一起会让整个 system 块每天都变一次；
    // 而它排在最前面，一变就把后面几千 token 的对话历史全部挤出 prompt 缓存。
    // ai_client 会把记忆挂到最后一条用户消息上，详见 _attachMemory。
    final memoryContext = await buildMemoryContext();
    final systemPrompt = _conversation.systemPrompt ?? basePersona;

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
      return jsonEncode({
        'success': false,
        'error': '工具 $toolName 执行失败: $e',
      });
    }
  }

  void _updateAssistantMessage(
    String content, {
    List<ToolCallInfo>? toolCalls,
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
        );
      } else {
        _conversation.messages.add(
          ChatMessage(
            id: 'stream_${_uuid.v4()}',
            role: MessageRole.assistant,
            content: cleaned,
            toolCalls: toolCalls,
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

  void _showSystemPromptDialog() {
    final controller = TextEditingController(
      text: _conversation.systemPrompt ?? '',
    );
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('系统提示词'),
            content: SizedBox(
              width: double.maxFinite,
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '设定 AI 的角色、人设、行为规则...',
                ),
                maxLines: 6,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _conversation.systemPrompt = null);
                  Navigator.of(ctx).pop();
                },
                child: const Text('重置默认'),
              ),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _conversation.systemPrompt = controller.text.trim();
                  });
                  Navigator.of(ctx).pop();
                },
                child: const Text('保存'),
              ),
            ],
          ),
    );
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
        if (msg.imageData != null) buffer.writeln('  [图片附件]');
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

  Widget _buildStatsCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    return FutureBuilder<WereadStats>(
      future: WereadService.fetchReadingStats(),
      builder: (ctx, snap) {
        final stats = snap.data;
        if (snap.hasError || stats == null) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.chartBar,
                    size: 18,
                    color: scheme.secondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '阅读统计',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  _statItem(scheme, '${stats.finishedThisMonth}', '本月读完'),
                  _statItem(scheme, '${stats.currentlyReading}', '在读'),
                  _statItem(scheme, '${stats.finishedThisYear}', '今年读完'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statItem(ColorScheme scheme, String num, String label) {
    return Expanded(
      child: Column(
        children: [
          Text(
            num,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _quickActionCard(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final scheme = theme.colorScheme;
    return Expanded(
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Icon(icon, color: scheme.secondary, size: 24),
                const SizedBox(height: 6),
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
                      ? Text(
                        _conversation.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fgColor),
                      )
                      : null),
          actions: [
            _topBarIcon(
              PhosphorIconsRegular.magnifyingGlass,
              onPressed: _openSearch,
              tooltip: '搜索',
              color: fgColor,
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
            // 内容区：主页模式显示首页，对话模式显示消息
            Expanded(
              child:
                  _chatMode
                      ? (_conversation.messages.isEmpty
                          ? _buildEmptyChatHint(theme)
                          : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(12),
                            itemCount: _conversation.messages.length,
                            itemBuilder: (context, index) {
                              final msg = _conversation.messages[index];
                              return chatMessageItem(msg);
                            },
                          ))
                      : _buildHome(theme),
            ),

            // Input area
            _buildInputArea(theme),
          ],
        ),
      ),
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
    return Drawer(
      // 实底：半透明会让背后花花绿绿的内容透上来，压低菜单文字的可读性
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Text(
                '菜单',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_chatMode) ...[
              _drawerItem(theme, PhosphorIconsRegular.pencilSimple, '重命名', () {
                Navigator.of(context).pop();
                _showRenameDialog();
              }),
              _drawerItem(theme, PhosphorIconsRegular.brain, '系统提示词', () {
                Navigator.of(context).pop();
                _showSystemPromptDialog();
              }),
              _drawerItem(theme, PhosphorIconsRegular.shareNetwork, '导出聊天', () {
                Navigator.of(context).pop();
                _exportConversation();
              }),
              const Divider(),
            ],
            _drawerItem(theme, PhosphorIconsRegular.plus, '新对话', () {
              Navigator.of(context).pop();
              _newConversation();
            }),
            _drawerItem(
              theme,
              PhosphorIconsRegular.clockCounterClockwise,
              '对话历史',
              () {
                Navigator.of(context).pop();
                _showConversationList();
              },
            ),
            // 「书架」不放这里：底部导航已经有了，同一个目的地两个入口只会
            // 让人多想一秒。「工具」是诊断页，收进设置里，不与设置平级。
            const Divider(),
            _drawerItem(theme, PhosphorIconsRegular.gear, '设置', () async {
              Navigator.of(context).pop();
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
              _loadUserName();
            }),
            _drawerItem(theme, PhosphorIconsRegular.imageSquare, '聊天背景', () {
              Navigator.of(context).pop();
              _showBackgroundSheet();
            }),
            const Divider(),
            _drawerItem(theme, PhosphorIconsRegular.trashSimple, '回收站', () {
              Navigator.of(context).pop();
              _showTrashSheet();
            }),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final scheme = theme.colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.onSurfaceVariant),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm)),
      onTap: onTap,
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

  Future<void> _showBackgroundSheet() async {
    final preset = await StorageService.getBackgroundPreset();
    final hasImage = _backgroundImagePath != null;
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
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
                    '聊天背景',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Divider(height: 1),
                _backgroundOption(
                  ctx,
                  scheme,
                  icon: PhosphorIconsRegular.sparkle,
                  label: '跟随主题',
                  desc: '浅色模式用浅色背景，深色模式用深色背景',
                  selected: !hasImage && preset == 'none',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _setBackgroundPreset('none');
                  },
                ),
                _backgroundOption(
                  ctx,
                  scheme,
                  icon: PhosphorIconsRegular.sun,
                  label: '浅色背景',
                  desc: '固定的浅色底色',
                  selected: !hasImage && preset == 'light',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _setBackgroundPreset('light');
                  },
                ),
                _backgroundOption(
                  ctx,
                  scheme,
                  icon: PhosphorIconsRegular.moon,
                  label: '深色背景',
                  desc: '固定的深色底色',
                  selected: !hasImage && preset == 'dark',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _setBackgroundPreset('dark');
                  },
                ),
                _backgroundOption(
                  ctx,
                  scheme,
                  icon: PhosphorIconsRegular.imageSquare,
                  label: '自定义图片',
                  desc: hasImage ? '当前已设置图片' : '从相册选择一张背景图',
                  selected: hasImage,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _pickBackground();
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
    );
  }

  Widget _backgroundOption(
    BuildContext ctx,
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String desc,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: selected ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(desc, style: const TextStyle(fontSize: 12)),
      trailing:
          selected ? const Icon(PhosphorIconsRegular.check, size: 20) : null,
      onTap: onTap,
    );
  }

  Future<void> _setBackgroundPreset(String preset) async {
    await StorageService.setBackgroundImagePath(null);
    await StorageService.setBackgroundPreset(preset);
    if (mounted) setState(() => _backgroundImagePath = null);
    widget.onBackgroundChanged?.call();
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
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        // 我想说
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: scheme.inverseSurface,
            borderRadius: BorderRadius.circular(AppRadius.md),
            boxShadow: [
              BoxShadow(
                color: scheme.inverseSurface.withValues(alpha: 0.25),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
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
                      color: scheme.onInverseSurface.withValues(alpha: 0.7),
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
                            color: scheme.onInverseSurface.withValues(alpha: 0.6),
                          ),
                        )
                      else
                        InkWell(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          onTap: _refreshMusing,
                          child: Icon(
                            PhosphorIconsRegular.arrowsClockwise,
                            size: 18,
                            color: scheme.onInverseSurface.withValues(alpha: 0.7),
                          ),
                        ),
                      const SizedBox(width: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        onTap:
                            _musingContent == null
                                ? null
                                : _toggleFavoriteMusing,
                        // 收藏了就换成实心 + 满亮度，没收藏是描边 + 压暗。
                        //
                        // 原来三元的两个分支是同一个 PhosphorIconsRegular.star，
                        // 两种状态长得一模一样，点了根本看不出有没有收上。
                        //
                        // 不给它上第二种彩色：这张卡是 inverseSurface 深底，
                        // 白色实心已经够跳，而全 App 只留赤陶一个强调色。
                        child: Icon(
                          _musingFavorited
                              ? PhosphorIconsFill.star
                              : PhosphorIconsRegular.star,
                          size: 20,
                          color:
                              _musingFavorited
                                  ? scheme.onInverseSurface
                                  : scheme.onInverseSurface.withValues(
                                    alpha: 0.55,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _musingContent ??
                    (_musingLoading ? '在想点什么…' : '开始新对话吧，我可以帮你拍照、查位置、聊书、找文件。'),
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.6,
                  color: scheme.onInverseSurface,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // 阅读统计
        _buildStatsCard(theme),
        const SizedBox(height: 14),

        // 快捷入口
        Row(
          children: [
            _quickActionCard(
              theme,
              PhosphorIconsRegular.plus,
              '新对话',
              _newConversation,
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              PhosphorIconsRegular.bookOpen,
              '书架',
              () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              PhosphorIconsRegular.desktop,
              '电脑',
              () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const PcChatScreen())),
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
        const SizedBox(height: 24),
        Center(
          child: Text(
            '也可以直接在下方输入框开始聊天',
            style: theme.textTheme.bodySmall?.copyWith(
              color: fgColor.withValues(alpha: 0.7),
            ),
          ),
        ),
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
          child: Material(
            // 置顶的压深一档并描一道边，在一列白卡片里一眼能挑出来
            color:
                pinned
                    ? scheme.primaryContainer.withValues(alpha: 0.92)
                    : Colors.white.withValues(alpha: 0.94),
            elevation: 0,
            shape:
                pinned
                    ? RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.35),
                      ),
                    )
                    : null,
            borderRadius: pinned ? null : BorderRadius.circular(AppRadius.md),
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
                  color: pinned ? scheme.onPrimaryContainer : null,
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
    );
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
      child: Row(
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
            // 发送键是这一行唯一的主操作，用强调色；「+」保持中性
            color: active ? scheme.primary : Colors.white.withValues(alpha: 0.85),
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
        fillColor: Colors.white.withValues(alpha: 0.75),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
      ),
    );
  }
}
