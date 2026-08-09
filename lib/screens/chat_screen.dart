import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../config/app_tab.dart';
import '../services/ai_client.dart';
import '../services/app_providers.dart';
import '../services/mcp_server.dart';
import '../services/storage_service.dart';
import '../services/vision_service.dart';
import '../services/weread_service.dart';
import '../services/memory_context.dart';
import '../models/musing_entry.dart';
import '../services/musing_generator.dart';
import '../search/history_search_delegate.dart';
import '../search/search_result_model.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_call_card.dart';
import 'tools_screen.dart';
import 'settings_screen.dart';
import 'pc_chat_screen.dart';

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
  final _uuid = const Uuid();
  final _picker = ImagePicker();
  stt.SpeechToText? _speech;
  bool _isListening = false;
  bool _isLoading = false;
  bool _voiceMode = false;
  bool _chatMode = false;
  List<Conversation> _savedConversations = [];
  String? _backgroundImagePath;
  String? _musingContent;
  bool _musingFavorited = false;
  bool _musingLoading = false;

  late Conversation _conversation;

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(id: _uuid.v4());
    _initSpeech();
    _loadConversations();
    _loadBackground();
    _loadMusing();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _speech?.cancel();
    super.dispose();
  }

  Future<void> _initSpeech() async {
    _speech = stt.SpeechToText();
    await _speech!.initialize();
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

  Future<void> _clearBackground() async {
    await StorageService.setBackgroundImagePath(null);
    if (mounted) setState(() => _backgroundImagePath = null);
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

  Future<void> _startListening() async {
    if (_speech == null || _isListening) return;

    final available = await _speech!.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech!.listen(
        onResult: (result) {
          _textController.text = result.recognizedWords;
          _textController.selection = TextSelection.fromPosition(
            TextPosition(offset: result.recognizedWords.length),
          );
        },
        localeId: 'zh_CN',
      );
    }
  }

  void _stopListening() {
    if (!_isListening) return;
    _speech?.stop();
    setState(() => _isListening = false);
    // 识别结果已填入输入框，切回文字模式方便编辑 / 发送
    if (mounted) setState(() => _voiceMode = false);
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
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      _attachmentItem(
                        ctx,
                        Icons.photo_camera_outlined,
                        '拍照',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickAndSendImage(ImageSource.camera),
                      ),
                      _attachmentItem(
                        ctx,
                        Icons.photo_library_outlined,
                        '相册',
                        () => Navigator.of(ctx).pop(),
                        action: () => _pickAndSendImage(ImageSource.gallery),
                      ),
                      _attachmentItem(
                        ctx,
                        Icons.insert_drive_file_outlined,
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
        borderRadius: BorderRadius.circular(16),
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

    const basePersona =
        '你是用户的好朋友、日常小伙伴。聊天要像真人朋友一样自然、亲切、有温度，'
        '重视和用户的关系，会主动关心用户。你也能用手机上的工具帮忙：'
        '拍照、查看文件、获取位置等，需要时主动使用，但别把对话变成干巴巴的任务交接。';
    final memoryContext = await buildMemoryContext();
    final systemPrompt =
        _conversation.systemPrompt ??
        (memoryContext.isEmpty
            ? basePersona
            : '$basePersona\n\n$memoryContext');

    // Loop: keep calling AI and executing tools until AI responds with text
    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;

      String? fullResponse;
      String? errorText;

      try {
        await for (final event in clientWithTools.chat(
          _conversation.messages,
          systemPrompt: systemPrompt,
        )) {
          switch (event.type) {
            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              _updateAssistantMessage(fullResponse ?? '');
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
              // Break out of the stream loop to continue the outer while loop
              fullResponse = null; // signal that we need another round
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              _updateAssistantMessage(fullResponse);
              break;

            case AiEventType.error:
              print('[chat] AI error: ${event.error}');
              _updateAssistantMessage('⚠️ 错误: ${event.error ?? "未知"}');
              _finalizeStreamMessage();
              fullResponse = 'done';
              break;
          }
        }
      } catch (e) {
        _updateAssistantMessage('❌ 发送消息失败: $e');
      }

      // If there was a tool call, the loop continues
      // If there was an error or done with text, exit
      if (fullResponse != null || errorText != null) break;
    }

    if (!mounted) return;
    setState(() => _isLoading = false);
    _scrollToBottom();
    _saveConversation();
  }

  Future<String> _executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    // Try local MCP server first
    final executor =
        mcpServer.registeredTools
            .where((r) => r.tool.name == tc.name)
            .firstOrNull
            ?.executor;
    if (executor != null) {
      final result = await executor(tc.arguments);
      return result.toString();
    }

    // Try external MCP servers
    final extProvider = context.read<ExternalMcpProvider>();
    for (final client in extProvider.clients) {
      if (client.tools.any((t) => t.name == tc.name)) {
        final result = await client.callTool(tc.name, tc.arguments);
        return result.toString();
      }
    }

    return '错误: 工具 ${tc.name} 未找到';
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
                        icon: const Icon(Icons.add, size: 18),
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
                          Icons.search,
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
                                    Icons.delete_outline,
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
      buffer.writeln('${'=' * 40}');
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
      _conversation.title =
          _conversation.messages.firstOrNull?.content?.substring(
            0,
            (_conversation.messages.first.content.length).clamp(0, 30),
          ) ??
          '新对话';
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
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.bar_chart_rounded,
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
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
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
                          Icons.arrow_back,
                          onPressed: _goHome,
                          tooltip: '返回主页',
                          color: fgColor,
                        )
                        : _topBarIcon(
                          Icons.menu_rounded,
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
                      Text(
                        _greeting(),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: fgColor,
                        ),
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
              Icons.search,
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
                              if (msg.role == MessageRole.toolCall &&
                                  msg.toolCalls != null) {
                                return ToolCallCard(toolCalls: msg.toolCalls!);
                              }
                              if (msg.role == MessageRole.toolResult) {
                                return ToolResultCard(content: msg.content);
                              }
                              return MessageBubble(message: msg);
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
    return '$part，Cleo';
  }

  String _homeDateStr() {
    final today = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${today.month}月${today.day}日 · ${weekdays[today.weekday - 1]}';
  }

  Widget _buildDrawer(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Drawer(
      backgroundColor: scheme.surface.withValues(alpha: 0.96),
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
              _drawerItem(theme, Icons.edit_outlined, '重命名', () {
                Navigator.of(context).pop();
                _showRenameDialog();
              }),
              _drawerItem(theme, Icons.psychology_outlined, '系统提示词', () {
                Navigator.of(context).pop();
                _showSystemPromptDialog();
              }),
              _drawerItem(theme, Icons.share_outlined, '导出聊天', () {
                Navigator.of(context).pop();
                _exportConversation();
              }),
              const Divider(),
            ],
            _drawerItem(theme, Icons.add_rounded, '新对话', () {
              Navigator.of(context).pop();
              _newConversation();
            }),
            _drawerItem(theme, Icons.history_rounded, '对话历史', () {
              Navigator.of(context).pop();
              _showConversationList();
            }),
            _drawerItem(theme, Icons.menu_book_rounded, '书架', () {
              Navigator.of(context).pop();
              widget.onSwitchTab?.call(AppTab.bookshelf);
            }),
            _drawerItem(theme, Icons.build_outlined, '工具', () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ToolsScreen()));
            }),
            _drawerItem(theme, Icons.settings_outlined, '设置', () {
              Navigator.of(context).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            }),
            _drawerItem(theme, Icons.wallpaper_outlined, '聊天背景', () {
              Navigator.of(context).pop();
              _showBackgroundSheet();
            }),
            const Divider(),
            _drawerItem(theme, Icons.delete_sweep_outlined, '回收站', () {
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                          borderRadius: BorderRadius.circular(2),
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
                                  Icons.delete_outline,
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
                                        if (ctx.mounted)
                                          Navigator.of(ctx).pop();
                                        _loadConversations();
                                      },
                                      child: const Text('恢复'),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_forever_outlined,
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
                    borderRadius: BorderRadius.circular(2),
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
                  icon: Icons.auto_awesome_outlined,
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
                  icon: Icons.light_mode_outlined,
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
                  icon: Icons.dark_mode_outlined,
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
                  icon: Icons.wallpaper_outlined,
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
      trailing: selected ? const Icon(Icons.check_rounded, size: 20) : null,
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
            Icons.chat_bubble_outline,
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
            color: scheme.primary,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.25),
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
                      color: scheme.onPrimary.withValues(alpha: 0.7),
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
                            color: scheme.onPrimary.withValues(alpha: 0.6),
                          ),
                        )
                      else
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: _refreshMusing,
                          child: Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: scheme.onPrimary.withValues(alpha: 0.7),
                          ),
                        ),
                      const SizedBox(width: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap:
                            _musingContent == null
                                ? null
                                : _toggleFavoriteMusing,
                        child: Icon(
                          _musingFavorited
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          size: 20,
                          color: scheme.onPrimary,
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
                  color: scheme.onPrimary,
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
            _quickActionCard(theme, Icons.add_rounded, '新对话', _newConversation),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              Icons.menu_book_rounded,
              '书架',
              () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            const SizedBox(width: 10),
            _quickActionCard(
              theme,
              Icons.computer_rounded,
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
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
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

  Widget _conversationTile(ThemeData theme, Conversation conv) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Text(
            conv.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          leading:
              conv.isPinned
                  ? Icon(Icons.push_pin, size: 18, color: scheme.primary)
                  : null,
          subtitle: Text(
            '${conv.messages.length} 条消息 · ${_shortTime(conv.updatedAt)}',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(
                  conv.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 18,
                  color:
                      conv.isPinned ? scheme.primary : scheme.onSurfaceVariant,
                ),
                tooltip: conv.isPinned ? '取消置顶' : '置顶',
                onPressed: () async {
                  await StorageService.setConversationPinned(
                    conv.id,
                    !conv.isPinned,
                  );
                  _loadConversations();
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () async {
                  await StorageService.deleteConversation(conv.id);
                  _loadConversations();
                  if (mounted) {
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
                  }
                },
              ),
            ],
          ),
          onTap: () => _switchConversation(conv),
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
          // 左侧圆圈：文字输入 / 语音输入 模式切换
          _circleToolButton(
            scheme,
            icon: _voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_none,
            tooltip: _voiceMode ? '切换为文字输入' : '切换为语音输入',
            active: _voiceMode,
            onTap:
                _isLoading
                    ? null
                    : () => setState(() => _voiceMode = !_voiceMode),
          ),
          const SizedBox(width: 8),
          Expanded(
            child:
                _voiceMode ? _buildHoldToTalk(theme) : _buildTextField(theme),
          ),
          const SizedBox(width: 8),
          // 右侧加号：拍照 / 相册 / 文件
          _circleToolButton(
            scheme,
            icon: Icons.add,
            tooltip: '更多功能',
            onTap: _isLoading ? null : _showAttachmentMenu,
          ),
          const SizedBox(width: 6),
          // Send button
          _circleToolButton(
            scheme,
            icon: _isLoading ? Icons.hourglass_empty : Icons.send_rounded,
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
            color:
                active
                    ? scheme.onSurface
                    : Colors.white.withValues(alpha: 0.85),
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? scheme.surface : scheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(ThemeData theme) {
    final scheme = theme.colorScheme;
    return TextField(
      controller: _textController,
      maxLines: 5,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      decoration: InputDecoration(
        hintText: '输入消息...',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
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

  Widget _buildHoldToTalk(ThemeData theme) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      onLongPressStart: (_) => _startListening(),
      onLongPressEnd: (_) => _stopListening(),
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        child: Text(
          _isListening ? '正在聆听...' : '按住说话',
          style: TextStyle(
            fontSize: 14,
            color: _isListening ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
