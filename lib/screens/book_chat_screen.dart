import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/discussion_note.dart';
import '../services/ai_client.dart';
import '../services/mcp_server.dart';
import '../widgets/message_bubble.dart';
import '../widgets/tool_call_card.dart';
import '../services/discussion_generator.dart';
import 'chat_screen.dart';

class BookChatScreen extends StatefulWidget {
  final String bookId;
  final String bookTitle;
  final String? bookAuthor;

  const BookChatScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    this.bookAuthor,
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

  String get _systemPrompt {
    final book = '《${widget.bookTitle}》';
    final author = widget.bookAuthor != null ? '（作者：${widget.bookAuthor}）' : '';
    return '我们正在一起聊$book$author这本书。'
        '你可以分享你对这本书的看法、感受、印象深刻的情节或人物，'
        '和用户互相交流观点，像两个读过这本书的朋友在聊天一样，'
        '而不是单纯回答问题。'
        '如果用户提到书中的具体内容，你可以展开讨论；'
        '如果用户表达感受，你可以回应并分享你的视角。';
  }

  @override
  void initState() {
    super.initState();
    _conversation = Conversation(
      id: 'book_${widget.bookId}',
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

  Future<Directory> get _bookConvDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/book_conversations');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

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

  Future<void> _showQuoteDialog() async {
    final quoteCtrl = TextEditingController();
    final commentCtrl = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('引用批注'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: quoteCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '引用文字',
                hintText: '粘贴你想讨论的段落...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: commentCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '你的想法',
                hintText: '关于这段文字，你想说什么？',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop({
              'quote': quoteCtrl.text.trim(),
              'comment': commentCtrl.text.trim(),
            }),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final quote = result['quote'] ?? '';
    final comment = result['comment'] ?? '';
    if (quote.isEmpty && comment.isEmpty) return;
    _textController.text =
        comment.isNotEmpty ? '> $quote\n\n$comment' : '> $quote';
    _sendMessage();
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
              _updateAssistantMessage(fullResponse ?? '', toolCalls: event.toolCalls ?? []);
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
    // 'no' or null → just leave
    return true;
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Discussion 笔记已生成')),
        );
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
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _handleBack();
        if (shouldPop && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            final shouldPop = await _handleBack();
            if (shouldPop && mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
        title: Text('《${widget.bookTitle}》'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _isLoading
              ? const LinearProgressIndicator()
              : const SizedBox.shrink(),
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
          _buildInputArea(theme),
        ],
      ),
    ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.menu_book_rounded,
              size: 80, color: theme.colorScheme.primary.withAlpha(60)),
          const SizedBox(height: 16),
          Text(
            '《${widget.bookTitle}》',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '开始聊聊这本书吧',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
            icon: const Icon(Icons.format_quote_outlined),
            onPressed: _isLoading ? null : _showQuoteDialog,
            tooltip: '引用批注',
          ),
          IconButton(
            icon: Icon(
              _isLoading ? Icons.stop : Icons.send_rounded,
              color: theme.colorScheme.primary,
            ),
            onPressed: _isLoading ? null : _sendMessage,
          ),
        ],
      ),
    );
  }
}
