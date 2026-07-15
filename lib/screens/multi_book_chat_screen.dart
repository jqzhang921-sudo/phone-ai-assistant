import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../models/book.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/discussion_note.dart';
import '../services/ai_client.dart';
import '../services/mcp_server.dart';
import '../services/discussion_generator.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_call_card.dart';
import 'chat_screen.dart';

class MultiBookChatScreen extends StatefulWidget {
  final List<Book> books;

  const MultiBookChatScreen({super.key, required this.books});

  @override
  State<MultiBookChatScreen> createState() => _MultiBookChatScreenState();
}

class _MultiBookChatScreenState extends State<MultiBookChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _uuid = const Uuid();
  bool _isLoading = false;
  late Conversation _conversation;

  String get _conversationId =>
      'multi_${widget.books.map((b) => b.id).join('_')}';

  String get _title =>
      widget.books.map((b) => '《${b.title}》').join(' · ');

  String get _systemPrompt {
    final names = widget.books.map((b) {
      final a = b.author != null ? '（${b.author}）' : '';
      return '《${b.title}》$a';
    }).join('、');
    return '我们正在一起聊这几本书：$names。'
        '你可以分享对这些书的看法，也可以对比它们之间的异同，'
        '像两个读过这些书的朋友在聊天一样，而不是单纯回答问题。'
        '如果用户提到某本书的具体内容，你可以展开讨论；'
        '也可以主动对比几本书在主题、人物、风格上的差异。';
  }

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(
      id: _conversationId,
      systemPrompt: _systemPrompt,
    );
    _loadConversation();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<Directory> get _convDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/book_conversations');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _loadConversation() async {
    try {
      final dir = await _convDir;
      final file = File('${dir.path}/${_conversation.id}.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        setState(() {
          _conversation = Conversation.fromJson(data);
          _conversation.systemPrompt = _systemPrompt;
        });
      }
    } catch (_) {}
  }

  Future<void> _saveConversation() async {
    final dir = await _convDir;
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

    setState(() {
      _conversation.messages.add(ChatMessage(
        id: _uuid.v4(),
        role: MessageRole.user,
        content: text,
      ));
      _isLoading = true;
    });
    _scrollToBottom();
    _continueChat();
  }

  Future<void> _continueChat() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    final mcpServer = context.read<McpServerProvider>().server;
    final externalTools = context.read<ExternalMcpProvider>().allExternalTools;

    if (aiClient == null) {
      setState(() {
        _conversation.messages.add(ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content: '请先在设置中配置 API Key',
        ));
        _isLoading = false;
      });
      return;
    }

    final allTools = [...mcpServer.registeredTools.map((r) => r.tool), ...externalTools];
    final clientWithTools = AiClient(config: aiClient.config, tools: allTools);

    int maxRounds = 5;
    while (maxRounds > 0) {
      maxRounds--;
      String? fullResponse;

      try {
        await for (final event in clientWithTools.chat(
          _conversation.messages,
          systemPrompt: _conversation.systemPrompt,
        )) {
          switch (event.type) {
            case AiEventType.token:
              fullResponse = (fullResponse ?? '') + (event.text ?? '');
              _updateAssistantMessage(fullResponse ?? '');
              break;

            case AiEventType.toolCalls:
              fullResponse = fullResponse ?? '';
              _updateAssistantMessage(fullResponse, toolCalls: event.toolCalls ?? []);
              _finalizeStreamMessage();
              for (final tc in event.toolCalls ?? []) {
                final toolResult = await _executeTool(mcpServer, tc);
                _conversation.messages.add(ChatMessage(
                  id: _uuid.v4(),
                  role: MessageRole.toolResult,
                  content: toolResult,
                  toolCallId: tc.id,
                ));
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

  Future<String> _executeTool(McpServer mcpServer, ToolCallInfo tc) async {
    final executor = mcpServer.registeredTools
        .where((r) => r.tool.name == tc.name)
        .firstOrNull
        ?.executor;
    if (executor != null) {
      final result = await executor(tc.arguments);
      return result.toString();
    }
    for (final client in context.read<ExternalMcpProvider>().clients) {
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

  Future<bool> _handleBack() async {
    if (_conversation.messages.isEmpty) return true;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开讨论'),
        content: const Text('要生成本次讨论的 Discussion 笔记吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('no'),
            child: const Text('不生成'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('保存对话'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('generate'),
            child: const Text('生成 Discussion'),
          ),
        ],
      ),
    );

    if (result == 'generate') {
      await _generateAndSaveDiscussion();
    } else if (result == 'save') {
      _saveConversation();
    }
    return true;
  }

  Future<void> _generateAndSaveDiscussion() async {
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;

    // Generate for each book
    for (final book in widget.books) {
      final content = await generateDiscussionForBook(
        bookId: book.id,
        bookTitle: book.title,
        aiClient: aiClient,
      );
      if (content != null) {
        final note = DiscussionNote(
          id: _uuid.v4(),
          bookId: book.id,
          content: content,
        );
        final prefs = await SharedPreferences.getInstance();
        final key = 'discussions_${book.id}';
        final raw = prefs.getString(key);
        final list = raw != null ? (jsonDecode(raw) as List) : [];
        list.insert(0, note.toJson());
        await prefs.setString(key, jsonEncode(list));
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Discussion 笔记已生成')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _handleBack();
        if (shouldPop && mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final shouldPop = await _handleBack();
              if (shouldPop && mounted) Navigator.of(context).pop();
            },
          ),
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: _isLoading ? const LinearProgressIndicator() : const SizedBox.shrink(),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: _conversation.messages.isEmpty
                  ? _buildEmptyState(theme)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _conversation.messages.length,
                      itemBuilder: (context, index) {
                        final msg = _conversation.messages[index];
                        if (msg.role == MessageRole.toolCall && msg.toolCalls != null) {
                          return ToolCallCard(toolCalls: msg.toolCalls!);
                        }
                        if (msg.role == MessageRole.toolResult) {
                          return ToolResultCard(content: msg.content);
                        }
                        return MessageBubble(message: msg);
                      },
                    ),
            ),
            _buildInputArea(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book_rounded, size: 64,
                color: theme.colorScheme.primary.withAlpha(60)),
            const SizedBox(height: 16),
            Text(_title, style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text('开始聊聊这几本书吧',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _buildInputArea(ThemeData theme) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        padding: EdgeInsets.only(
          left: 12, right: 8, top: 8,
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
                  hintText: '聊聊这几本书...',
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
            IconButton(
              icon: Icon(_isLoading ? Icons.stop : Icons.send_rounded,
                  color: theme.colorScheme.primary),
              onPressed: _isLoading ? null : _sendMessage,
            ),
          ],
        ),
      );
}
