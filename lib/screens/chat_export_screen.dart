import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../models/chat_message.dart';
import '../services/chat_export.dart';
import '../services/shared_text.dart';
import '../widgets/app_surface.dart';

/// 导出这场讨论：整场，或者只挑几句。
///
/// ## 为什么另开一页，而不是在聊天页上长按选中
///
/// 长按气泡进多选，是聊天软件的做法，但那要改 [MessageBubble]——而它同时被
/// 主 App 和读书版用着，为一个导出功能给它加一层选中态，两边都要跟着担风险。
///
/// 另开一页还有个好处：**这里能一眼看全**。要挑「刚才聊到母亲那几句」，
/// 在聊天页里得来回滚，在这儿是一列紧凑的行，勾就完了。
///
/// ## 为什么只有复制和分享，没有「存成文件」
///
/// 写进 Download 要过 MediaStore 和存储权限那一套。而**系统分享面板本来就
/// 通向所有地方**——微信、便签、网盘、Telegram，想存哪存哪，还不用向他要
/// 任何权限。少一个权限申请，比多一个按钮值钱。
class ChatExportScreen extends StatefulWidget {
  final List<ChatMessage> messages;
  final String bookTitle;
  final String? bookAuthor;

  const ChatExportScreen({
    super.key,
    required this.messages,
    required this.bookTitle,
    this.bookAuthor,
  });

  @override
  State<ChatExportScreen> createState() => _ChatExportScreenState();
}

class _ChatExportScreenState extends State<ChatExportScreen> {
  /// 有正文的那些。工具调用那几条没有内容，列出来是一排空行。
  late final List<ChatMessage> _items =
      widget.messages.where((m) => m.content.trim().isNotEmpty).toList();

  /// 默认全选。
  ///
  /// 「导出整场」是最常见的意图，挑几句是次要的。默认全选的话，
  /// 常见情况零操作；反过来则每次都要先点「全选」。
  late final Set<String> _picked = _items.map((m) => m.id).toSet();

  bool get _all => _picked.length == _items.length;

  List<ChatMessage> get _selected =>
      _items.where((m) => _picked.contains(m.id)).toList();

  String _text() => ChatExport.format(
    _selected,
    bookTitle: widget.bookTitle,
    bookAuthor: widget.bookAuthor,
  );

  void _toggle(ChatMessage m) {
    setState(() {
      if (!_picked.remove(m.id)) _picked.add(m.id);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_all) {
        _picked.clear();
      } else {
        _picked
          ..clear()
          ..addAll(_items.map((m) => m.id));
      }
    });
  }

  Future<void> _copy() async {
    final text = _text();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('复制了 ${_picked.length} 条'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _share() async {
    final text = _text();
    if (text.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await SharedTextChannel.sendOut(
      text,
      subject: '《${widget.bookTitle}》讨论',
    );
    if (!mounted || ok) return;
    // 分享面板起不来（比如系统限制）就退回复制，别让他白点一下。
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(
      const SnackBar(content: Text('分享起不来，已经复制到剪贴板了')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final empty = _picked.isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('导出 · ${_picked.length}/${_items.length}'),
        actions: [
          TextButton(
            onPressed: _items.isEmpty ? null : _toggleAll,
            child: Text(_all ? '全不选' : '全选'),
          ),
        ],
      ),
      body:
          _items.isEmpty
              ? Center(
                child: Text(
                  '还没有可导出的内容',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
              : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: _items.length,
                itemBuilder: (_, i) => _row(_items[i], theme, scheme),
              ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: empty ? null : _copy,
                  icon: const Icon(PhosphorIconsRegular.copy, size: 18),
                  label: const Text('复制'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: empty ? null : _share,
                  icon: const Icon(PhosphorIconsRegular.shareNetwork, size: 18),
                  label: const Text('分享出去'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ChatMessage m, ThemeData theme, ColorScheme scheme) {
    final on = _picked.contains(m.id);
    final mine = m.role == MessageRole.user;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppSurface(
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _toggle(m),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  value: on,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => _toggle(m),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mine ? '我' : 'AI',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: mine ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        m.content.trim(),
                        // 三行够认出是哪一句了，再多这一页就滚不动。
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
