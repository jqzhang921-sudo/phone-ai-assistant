import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_shape.dart';
import '../config/settings.dart';
import '../models/letter.dart';
import '../services/app_providers.dart';
import '../services/letter_generator.dart';
import '../services/storage_service.dart';

/// 信箱。
///
/// 和「我想说」的区别是它会等你：musing 过了今天就没了，信堆在这儿、有未读、
/// 而且能回。能回是关键——没有回信，信就只是一封长的 musing。
class LetterScreen extends StatefulWidget {
  const LetterScreen({super.key});

  @override
  State<LetterScreen> createState() => _LetterScreenState();
}

class _LetterScreenState extends State<LetterScreen> {
  final _uuid = const Uuid();
  List<Letter> _letters = [];
  bool _loading = true;
  bool _replying = false;
  String _userName = '';
  String _aiName = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final letters = await StorageService.listLetters();
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _letters = letters;
      _userName = settings.userName;
      _aiName = settings.aiName;
      _loading = false;
    });
    await _replyToPendingLetter();
  }

  /// 最新一封是用户写的、还没被回 → 现在回。
  ///
  /// 写完信当场就会生成回信，这里是给那次失败（断网之类）兜底的：下次进信箱
  /// 自动重试，不用额外做一个「重试」按钮。
  Future<void> _replyToPendingLetter() async {
    if (_letters.isEmpty || _replying) return;
    final newest = _letters.first;
    if (newest.isFromAi) return;

    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;

    setState(() => _replying = true);
    try {
      final reply = await generateReply(
        aiClient: aiClient,
        userLetter: newest,
      );
      if (reply != null) {
        await StorageService.addLetter(
          Letter(
            id: _uuid.v4(),
            author: LetterAuthor.ai,
            content: reply,
            replyToId: newest.id,
          ),
        );
        final letters = await StorageService.listLetters();
        if (mounted) setState(() => _letters = letters);
      }
    } catch (_) {
      // 回信失败不打扰，下次进来再试
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  Future<void> _openLetter(Letter letter) async {
    if (letter.isFromAi && !letter.read) {
      await StorageService.markLetterRead(letter.id);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => _LetterDetailScreen(
              letter: letter,
              userName: _userName,
              aiName: _aiName,
            ),
      ),
    );
    await _load();
  }

  Future<void> _compose({Letter? replyTo}) async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _ComposeLetterScreen(replyTo: replyTo)),
    );
    if (sent == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('信'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child:
              _replying
                  ? const LinearProgressIndicator()
                  : const SizedBox.shrink(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _compose(),
        icon: const Icon(PhosphorIconsRegular.pencilSimple),
        label: const Text('写一封'),
      ),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _letters.isEmpty
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    '还没有信。\n\n'
                    '聊得多了、日记攒下了、书读完了，它会写一封过来。'
                    '你也可以先写给它。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.7,
                    ),
                  ),
                ),
              )
              : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                // 多出来的第一项是「它在写回信…」，写完就消失
                itemCount: _letters.length + (_replying ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (_replying && index == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '它在写回信…',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  final letter = _letters[index - (_replying ? 1 : 0)];
                  return _LetterCard(
                    letter: letter,
                    onTap: () => _openLetter(letter),
                  );
                },
              ),
    );
  }
}

class _LetterCard extends StatelessWidget {
  final Letter letter;
  final VoidCallback onTap;

  const _LetterCard({required this.letter, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final unread = letter.isFromAi && !letter.read;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color:
                unread
                    ? scheme.primary.withValues(alpha: 0.45)
                    : scheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  letter.isFromAi
                      ? PhosphorIconsRegular.envelopeSimple
                      : PhosphorIconsRegular.paperPlaneTilt,
                  size: 16,
                  color: unread ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  letter.isFromAi ? '它写给你' : '你写的',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: unread ? scheme.primary : scheme.onSurfaceVariant,
                    fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (unread) ...[
                  const SizedBox(width: 6),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  _formatDate(letter.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              letter.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.8),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 信纸。日期和落款都由界面渲染——模型不知道今天几号，让它写日期一定会错。
class _LetterDetailScreen extends StatelessWidget {
  final Letter letter;
  final String userName;
  final String aiName;

  const _LetterDetailScreen({
    required this.letter,
    required this.userName,
    required this.aiName,
  });

  /// 落款：AI 的信用设置里的名字，你的信用你的名字。任一为空就不落款。
  String get _signature => letter.isFromAi ? aiName : userName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(letter.isFromAi ? '它写给你' : '你写的'),
        actions: [
          IconButton(
            tooltip: '删除',
            icon: const Icon(PhosphorIconsRegular.trash),
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      floatingActionButton:
          letter.isFromAi
              ? FloatingActionButton.extended(
                onPressed: () async {
                  final sent = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => _ComposeLetterScreen(replyTo: letter),
                    ),
                  );
                  if (sent == true && context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(PhosphorIconsRegular.pencilSimple),
                label: const Text('回信'),
              )
              : null,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 96),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatDate(letter.createdAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'NotoSerifSC',
                ),
              ),
            ),
            const SizedBox(height: 20),
            SelectableText(
              letter.content,
              style: TextStyle(
                fontFamily: 'NotoSerifSC',
                fontSize: 15.5,
                height: 1.95,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 24),
            if (_signature.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  _signature,
                  style: TextStyle(
                    fontFamily: 'NotoSerifSC',
                    fontSize: 15,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删除这封信'),
            content: const Text('删了就找不回来了。'),
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
    if (ok != true) return;
    await StorageService.deleteLetter(letter.id);
    if (context.mounted) Navigator.of(context).pop();
  }
}

/// 写信。发出后当场生成回信——先把闭环跑通，「延迟送达」那种慢节奏留到以后。
class _ComposeLetterScreen extends StatefulWidget {
  final Letter? replyTo;

  const _ComposeLetterScreen({this.replyTo});

  @override
  State<_ComposeLetterScreen> createState() => _ComposeLetterScreenState();
}

class _ComposeLetterScreenState extends State<_ComposeLetterScreen> {
  final _controller = TextEditingController();
  final _uuid = const Uuid();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 只负责存下用户这封信，然后立刻返回。
  ///
  /// 回信交给信箱去生成——它本来就有「最新一封是用户写的、还没被回就补上」
  /// 的逻辑，走同一条路。这样你写完就能走，不用被扣在这一页等模型。
  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final navigator = Navigator.of(context);
    setState(() => _sending = true);

    await StorageService.addLetter(
      Letter(
        id: _uuid.v4(),
        author: LetterAuthor.user,
        content: text,
        replyToId: widget.replyTo?.id,
      ),
    );

    if (!mounted) return;
    navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.replyTo == null ? '写一封信' : '回信'),
        actions: [
          IconButton(
            tooltip: '寄出',
            icon:
                _sending
                    ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(PhosphorIconsRegular.paperPlaneTilt),
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_sending,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  fontFamily: 'NotoSerifSC',
                  fontSize: 15.5,
                  height: 1.9,
                ),
                decoration: const InputDecoration(
                  hintText: '慢慢写，不着急。',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime t) {
  final local = t.toLocal();
  return '${local.year} 年 ${local.month} 月 ${local.day} 日';
}
