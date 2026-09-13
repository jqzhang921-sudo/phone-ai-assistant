import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/book.dart';
import '../config/reading_persona.dart';
import '../models/conversation.dart';
import '../models/discussion_note.dart';
import '../services/book_chat_streaming.dart';
import '../services/discussion_generator.dart';
import '../services/discussion_group_service.dart';
import '../widgets/chat_message_item.dart';
import '../services/app_providers.dart';
import '../config/app_shape.dart';

class MultiBookChatScreen extends StatefulWidget {
  final List<Book> books;
  final String? groupId;

  const MultiBookChatScreen({super.key, required this.books, this.groupId});

  @override
  State<MultiBookChatScreen> createState() => _MultiBookChatScreenState();
}

class _MultiBookChatScreenState extends State<MultiBookChatScreen>
    with BookChatStreaming<MultiBookChatScreen> {
  @override
  final TextEditingController textController = TextEditingController();
  @override
  final ScrollController scrollController = ScrollController();
  final _uuid = const Uuid();

  @override
  late Conversation conversation;

  String get _conversationId =>
      widget.groupId != null
          ? 'group_${widget.groupId}'
          : 'multi_${widget.books.map((b) => b.id).join('_')}';

  String get _title => widget.books.map((b) => '《${b.title}》').join(' · ');

  /// 多本一起聊，人设跟单本共用一份（见 [readingPersona]）。
  ///
  /// 只在开头把书列出来，性格那一整段原样复用——「引导型」这件事跟聊几本
  /// 没关系。两边各写一份的话，改了一处忘了另一处，用户会发现单本和多本
  /// 里的它性格不一样。
  @override
  String get systemPrompt {
    final names = widget.books
        .map((b) {
          final a = b.author != null ? '（${b.author}）' : '';
          return '《${b.title}》$a';
        })
        .join('、');
    return '$readingPersona\n\n'
        '这次一起聊这几本：$names。\n'
        '书和书之间的照应、分歧、互相解释的地方，是这种多本讨论最值得挖的，'
        '但别硬凑——没有关联就老实说没有。';
  }

  @override
  void initState() {
    super.initState();
    conversation = Conversation(
      id: _conversationId,
      systemPrompt: systemPrompt,
    );
    loadConversation();
  }

  @override
  void dispose() {
    textController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<bool> _handleBack() async {
    if (conversation.messages.isEmpty) return true;

    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('离开讨论'),
            content: const Text('要生成本次讨论的笔记吗？'),
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
                child: const Text('生成讨论笔记'),
              ),
            ],
          ),
    );

    if (result == 'generate') {
      await _generateAndSaveDiscussion();
    } else if (result == 'save') {
      saveConversation();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('讨论笔记已生成')));
    }
  }

  Future<void> _showGroupManageSheet() async {
    if (widget.groupId == null) return;

    final groups = await DiscussionGroupService.listGroups();
    final group = groups.where((g) => g.id == widget.groupId).firstOrNull;
    if (group == null) return;

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('管理讨论集合', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 16),

                  // Rename
                  ListTile(
                    leading: const Icon(PhosphorIconsRegular.pencilSimple),
                    title: const Text('重命名'),
                    subtitle: Text(group.name),
                    onTap: () async {
                      Navigator.of(ctx).pop();
                      final controller = TextEditingController(
                        text: group.name,
                      );
                      final result = await showDialog<String>(
                        context: context,
                        builder:
                            (dctx) => AlertDialog(
                              title: const Text('重命名集合'),
                              content: TextField(
                                controller: controller,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  hintText: '输入新名称',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(dctx).pop(),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed:
                                      () => Navigator.of(
                                        dctx,
                                      ).pop(controller.text.trim()),
                                  child: const Text('确定'),
                                ),
                              ],
                            ),
                      );
                      if (result != null && result.isNotEmpty && mounted) {
                        await DiscussionGroupService.saveGroup(
                          id: group.id,
                          name: result,
                          bookIds: group.bookIds,
                        );
                        if (mounted) setState(() {});
                      }
                    },
                  ),

                  // Book list
                  ListTile(
                    leading: const Icon(PhosphorIconsRegular.bookOpen),
                    title: Text('${widget.books.length}本'),
                    subtitle: Text(widget.books.map((b) => b.title).join('、')),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
    );
  }

  String get bookCountLabel => '${widget.books.length}本';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 先取 Navigator 再 await，理由同 book_chat_screen。
        final navigator = Navigator.of(context);
        final shouldPop = await _handleBack();
        if (shouldPop && mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(PhosphorIconsRegular.arrowLeft),
            onPressed: () async {
              final navigator = Navigator.of(context);
              final shouldPop = await _handleBack();
              if (shouldPop && mounted) navigator.pop();
            },
          ),
          title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (widget.groupId != null)
              IconButton(
                icon: const Icon(PhosphorIconsRegular.dotsThree),
                tooltip: '管理讨论集合',
                onPressed: _showGroupManageSheet,
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
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          PhosphorIconsRegular.bookOpen,
          size: 64,
          color: theme.colorScheme.primary.withAlpha(60),
        ),
        const SizedBox(height: 16),
        Text(
          _title,
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '开始聊聊这几本书吧',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );

  Widget _buildInputArea(ThemeData theme) => Container(
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
              hintText: '聊聊这几本书...',
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
        // 同 book_chat_screen：生成中禁用发送，不再摆一个点了没反应的停止键。
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
