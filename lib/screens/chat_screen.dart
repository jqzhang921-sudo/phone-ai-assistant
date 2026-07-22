import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/mcp_tool.dart';
import '../services/ai_client.dart';
import '../services/mcp_server.dart';
import '../services/storage_service.dart';
import '../services/external_mcp_client.dart';
import '../services/external_mcp_service.dart';
import '../search/history_search_delegate.dart';
import '../search/search_result_model.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_call_card.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

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
  List<Conversation> _savedConversations = [];

  late Conversation _conversation;

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(id: _uuid.v4());
    _initSpeech();
    _loadConversations();
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

  void _switchConversation(Conversation conv) {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = conv;
      _isLoading = false;
      _textController.clear();
    });
    Navigator.of(context).maybePop().then((_) {
      _scrollToBottom();
    });
  }

  void _newConversation() {
    if (_conversation.messages.isNotEmpty) _saveConversation();
    setState(() {
      _conversation = Conversation(id: _uuid.v4());
      _isLoading = false;
      _textController.clear();
    });
    Navigator.of(context).maybePop();
    _loadConversations();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        // Try again after layout settles
        Future.delayed(const Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
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

  Future<void> _pickAndSendImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
    );
    if (image == null) return;
    final bytes = await image.readAsBytes();
    final base64 = base64Encode(bytes);

    final text = _textController.text.trim();
    _textController.clear();

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: text.isEmpty ? '分析这张图片' : text,
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
    if (_speech == null) return;
    if (_isListening) {
      _speech!.stop();
      setState(() => _isListening = false);
      return;
    }

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
    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;

    if (aiClient == null) {
      setState(() {
        _conversation.messages.add(ChatMessage(
          id: _uuid.v4(), role: MessageRole.assistant,
          content: '⚠️ 请先在设置中配置 API Key',
        ));
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

    // Loop: keep calling AI and executing tools until AI responds with text
    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;

      String? fullResponse;
      String? errorText;

      try {
        await for (final event in clientWithTools.chat(
          _conversation.messages,
          systemPrompt: _conversation.systemPrompt ?? '你是一个手机 AI 助手。你可以使用手机上的工具来帮助用户：拍照、查看文件、获取位置等。请根据用户的需求主动使用这些工具。',
        )) {
          switch (event.type) {
            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              _updateAssistantMessage(fullResponse ?? '');
              break;

            case AiEventType.toolCalls:
              fullResponse = fullResponse ?? '';
              // Embed tool calls in the assistant message, then finalize
              _updateAssistantMessage(fullResponse, toolCalls: event.toolCalls ?? []);
              _finalizeStreamMessage();
              for (final tc in event.toolCalls ?? []) {
                final toolResult = await _executeTool(mcpServer, tc);
                _conversation.messages.add(ChatMessage(
                  id: _uuid.v4(), role: MessageRole.toolResult,
                  content: toolResult, toolCallId: tc.id,
                ));
              }
              // Break out of the stream loop to continue the outer while loop
              fullResponse = null; // signal that we need another round
              break;

            case AiEventType.done:
              fullResponse = event.text ?? fullResponse ?? '';
              _updateAssistantMessage(fullResponse);
              break;

            case AiEventType.error:
              // Show friendly message instead of raw error, let conversation continue
              _updateAssistantMessage(
                event.error?.contains('400') == true
                    ? '抱歉，该模型暂不支持图片识别，请用文字描述 🙏'
                    : event.error?.contains('401') == true
                        ? 'API 密钥无效或已过期，请在设置中更新 🙏'
                        : '抱歉，我遇到了一点问题，请再试一次 🙏',
              );
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
    final executor = mcpServer.registeredTools
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

  void _updateAssistantMessage(String content, {List<ToolCallInfo>? toolCalls}) {
    setState(() {
      if (_conversation.messages.isNotEmpty &&
          _conversation.messages.last.role == MessageRole.assistant &&
          _conversation.messages.last.id.startsWith('stream_')) {
        _conversation.messages.last = ChatMessage(
          id: _conversation.messages.last.id,
          role: MessageRole.assistant,
          content: content,
          toolCalls: toolCalls,
        );
      } else {
        _conversation.messages.add(ChatMessage(
          id: 'stream_${_uuid.v4()}',
          role: MessageRole.assistant,
          content: content,
          toolCalls: toolCalls,
        ));
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
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Text('对话历史', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 20,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 10),
                    Text('搜索历史对话',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _savedConversations.isEmpty
                  ? const Center(child: Text('暂无历史对话'))
                  : ListView.builder(
                      itemCount: _savedConversations.length,
                      itemBuilder: (ctx, i) {
                        final conv = _savedConversations[i];
                        final isCurrent = conv.id == _conversation.id;
                        return ListTile(
                          title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${conv.messages.length} 条消息 · ${conv.model}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: isCurrent,
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              await StorageService.deleteConversation(conv.id);
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
      builder: (ctx) => AlertDialog(
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
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(onPressed: () {
            setState(() {
              _conversation.title = controller.text.trim();
              _conversation.titleManuallySet = true;
            });
            _saveConversation();
            Navigator.of(ctx).pop();
          }, child: const Text('确定')),
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
      builder: (ctx) => AlertDialog(
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
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(onPressed: () {
            setState(() => _conversation.systemPrompt = null);
            Navigator.of(ctx).pop();
          }, child: const Text('重置默认')),
          FilledButton(onPressed: () {
            setState(() {
              _conversation.systemPrompt = controller.text.trim();
            });
            Navigator.of(ctx).pop();
          }, child: const Text('保存')),
        ],
      ),
    );
  }

  Future<void> _exportConversation() async {
    if (_conversation.messages.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有消息可以导出')),
      );
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
          case MessageRole.user: role = '👤 你';
          case MessageRole.assistant: role = '🤖 AI';
          case MessageRole.toolCall: role = '🛠 工具';
          case MessageRole.toolResult: role = '📋 结果';
          default: role = '📝 系统';
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

      await Share.shareXFiles(
        [XFile(file.path)],
        text: '📱 手机 AI 助手 - ${_conversation.title}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e')),
        );
      }
    }
  }

  void _saveConversation() {
    if (!_conversation.titleManuallySet) {
      _conversation.title = _conversation.messages.firstOrNull?.content
              ?.substring(0, (_conversation.messages.first.content.length).clamp(0, 30)) ??
          '新对话';
    }
    StorageService.saveConversation(_conversation);
  }

  Widget _buildDashboard(ThemeData theme) {
    const warmBg = Color(0xFFF5F7F3);
    const warmFg = Color(0xFF3D5C3A);
    const darkCard = Color(0xFF1F2A1E);
    const mutedText = Color(0xFF8A9686);

    final today = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final dateStr = '${today.month}月${today.day}日 · ${weekdays[today.weekday - 1]}';

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.78,
      child: Container(
        color: warmBg,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  children: [
              // Header
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('下午好，Cleo',
                            style: TextStyle(
                                fontSize: 22, fontWeight: FontWeight.w700,
                                color: darkCard)),
                        const SizedBox(height: 4),
                        Text(dateStr,
                            style: TextStyle(fontSize: 13, color: mutedText)),
                      ],
                    ),
                  ),
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3EBE0),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 18, color: warmFg),
                      onPressed: () => Navigator.of(context).pop(),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),

              // Daily summary card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: darkCard, borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('今日小结',
                        style: TextStyle(fontSize: 12, color: warmFg.withValues(alpha: 0.6))),
                    const SizedBox(height: 10),
                    Text(
                      '今天已进行了 ${_conversation.messages.length} 轮对话，'
                      '帮你处理了多项任务。'
                      '${_conversation.messages.isNotEmpty ? "最近在聊：${_conversation.title}" : "开始新对话吧！"}',
                      style: const TextStyle(fontSize: 15, color: Color(0xFFF0F4EE),
                          height: 1.6),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Quick actions
              Row(
                children: [
                  _dashActionCard(warmFg, Icons.add, '新对话', () {
                    Navigator.of(context).pop();
                    _newConversation();
                  }),
                  const SizedBox(width: 10),
                  _dashActionCard(warmFg, Icons.menu_book_rounded, '书架', () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pushNamed('/bookshelf');
                  }),
                ],
              ),
              const SizedBox(height: 16),

              // Quick links
              ...[
                (Icons.history, '对话历史', () { Navigator.of(context).pop(); _showConversationList(); }),
                (Icons.build_outlined, 'MCP 工具', () { Navigator.of(context).pop(); Navigator.of(context).pushNamed('/tools'); }),
              ].map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      leading: Icon(e.$1, color: warmFg, size: 22),
                      title: Text(e.$2,
                          style: const TextStyle(fontSize: 15, color: Color(0xFF3D4A3A))),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      onTap: () => e.$3.call(),
                    ),
                  )),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 16),
              child: IconButton(
                icon: Icon(Icons.settings_outlined,
                    color: warmFg.withValues(alpha: 0.35), size: 20),
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pushNamed('/settings');
                },
                tooltip: '设置',
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _dashActionCard(Color fg, IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: [
              Icon(icon, color: fg, size: 24),
              const SizedBox(height: 6),
              Text(label, style: TextStyle(fontSize: 13, color: fg)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      drawer: _buildDashboard(theme),
      appBar: AppBar(
        title: Text(_conversation.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'new') _newConversation();
              else if (v == 'history') _showConversationList();
              else if (v == 'bookshelf') Navigator.of(context).pushNamed('/bookshelf');
              else if (v == 'rename') _showRenameDialog();
              else if (v == 'export') _exportConversation();
              else if (v == 'system_prompt') _showSystemPromptDialog();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'new', child: ListTile(
                leading: Icon(Icons.add), title: Text('新对话'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
              const PopupMenuItem(value: 'history', child: ListTile(
                leading: Icon(Icons.history), title: Text('对话历史'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
              const PopupMenuItem(value: 'bookshelf', child: ListTile(
                leading: Icon(Icons.menu_book_rounded), title: Text('书架'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
              const PopupMenuItem(value: 'rename', child: ListTile(
                leading: Icon(Icons.edit), title: Text('重命名'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
              const PopupMenuItem(value: 'system_prompt', child: ListTile(
                leading: Icon(Icons.psychology), title: Text('系统提示词'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
              const PopupMenuItem(value: 'export', child: ListTile(
                leading: Icon(Icons.share), title: Text('导出聊天'),
                dense: true, visualDensity: VisualDensity.compact,
              )),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _isLoading
              ? const LinearProgressIndicator()
              : const SizedBox.shrink(),
        ),
      ),
      body: Column(
        children: [
          // Messages area
          Expanded(
            child: _conversation.messages.isEmpty
                ? _buildEmptyState(theme)
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
                  ),
          ),

          // Input area
          _buildInputArea(theme),
        ],
      ),
      floatingActionButton: context.watch<McpServerProvider>().server.isRunning
          ? null
          : FloatingActionButton.small(
              onPressed: () => Navigator.of(context).pushNamed('/tools'),
              tooltip: 'MCP 工具',
              child: const Icon(Icons.build),
            ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 80, color: theme.colorScheme.primary.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            '手机 AI 助手',
            style: theme.textTheme.headlineSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '我可以帮你拍照、查看文件、获取位置...\n试试看！',
            textAlign: TextAlign.center,
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
        border: Border(
          top: BorderSide(color: theme.dividerColor),
        ),
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
          // Image picker
          IconButton(
            icon: const Icon(Icons.image_outlined),
            onPressed: _isLoading ? null : _pickAndSendImage,
            tooltip: '发送图片',
          ),
          // Voice input
          IconButton(
            icon: Icon(
              _isListening ? Icons.mic : Icons.mic_none,
              color: _isListening ? Colors.red : null,
            ),
            onPressed: _isLoading ? null : _startListening,
            tooltip: _isListening ? '停止录音' : '语音输入',
          ),
          // Text input
          Expanded(
            child: TextField(
              controller: _textController,
              maxLines: 5,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Send button
          IconButton(
            icon: Icon(
              _isLoading ? Icons.stop : Icons.send_rounded,
              color: theme.colorScheme.primary,
            ),
            onPressed: _isLoading
                ? () {
                    // TODO: cancel stream
                  }
                : _sendMessage,
          ),
        ],
      ),
    );
  }
}

// Providers for state management
class AiClientProvider extends ChangeNotifier {
  AiClient? _currentClient;
  AiClient? get currentClient => _currentClient;

  void setClient(AiClient? client) {
    _currentClient = client;
    notifyListeners();
  }
}

class McpServerProvider extends ChangeNotifier {
  final McpServer _server = McpServer();
  McpServer get server => _server;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  void markInitialized() {
    _isInitialized = true;
    notifyListeners();
  }
}

class ExternalMcpProvider extends ChangeNotifier {
  final List<ExternalMcpClient> _clients = [];
  List<ExternalMcpClient> get clients => List.unmodifiable(_clients);
  bool _connecting = false;
  bool get connecting => _connecting;

  List<McpTool> get allExternalTools =>
      _clients.where((c) => c.connected).expand((c) => c.tools).toList();

  /// Returns null on success, or an error message string on failure.
  Future<String?> connectTo(ExternalMcpServer config) async {
    _clients.removeWhere((c) => c.config.url == config.url);
    _connecting = true;
    notifyListeners();

    final client = ExternalMcpClient(config: config);
    final ok = await client.connect();
    _connecting = false;

    if (ok) {
      _clients.add(client);
      notifyListeners();
      return null;
    } else {
      notifyListeners();
      return client.lastError ?? '连接失败，请检查服务器是否运行';
    }
  }

  Future<void> disconnect(String url) async {
    final client = _clients.where((c) => c.config.url == url).firstOrNull;
    if (client != null) {
      await client.disconnect();
      _clients.remove(client);
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> callExternalTool(
      String url, String toolName, Map<String, dynamic> args) async {
    final client = _clients.where((c) => c.config.url == url).firstOrNull;
    if (client == null) {
      return {'success': false, 'error': '未连接到 $url'};
    }
    return client.callTool(toolName, args);
  }

  void reconnectToEnabled(List<ExternalMcpServer> configs) async {
    for (final cfg in configs.where((c) => c.enabled)) {
      // Skip if already connected
      if (_clients.any((c) => c.config.url == cfg.url)) continue;
      await Future.delayed(const Duration(milliseconds: 500));
      await connectTo(cfg);
    }
    // Remove connections to servers no longer in config
    final urls = configs.map((c) => c.url).toList();
    for (final client in _clients.toList()) {
      if (!urls.contains(client.config.url)) {
        await client.disconnect();
        _clients.remove(client);
      }
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final c in _clients) {
      c.disconnect();
    }
    super.dispose();
  }
}
