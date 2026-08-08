import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/app_tab.dart';
import '../services/app_providers.dart';
import '../services/storage_service.dart';
import 'diary_screen.dart';
import 'musing_corner_screen.dart';

/// 「栖息」页：给用户留的专属空间（陪伴状态 / 阅读角落 / 日记）。
class HabitatScreen extends StatefulWidget {
  final void Function(AppTab tab)? onSwitchTab;

  const HabitatScreen({super.key, this.onSwitchTab});

  @override
  State<HabitatScreen> createState() => _HabitatScreenState();
}

class _HabitatScreenState extends State<HabitatScreen> {
  int _todayMessages = 0;
  int _totalMessages = 0;
  int _readingCount = 0;
  int _diaryCount = 0;
  int _musingCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final convs = await StorageService.listConversations();
    final diaries = await StorageService.listDiaryEntries();
    final musings = await StorageService.listFavoritedMusings();
    final now = DateTime.now();
    var today = 0;
    var total = 0;
    for (final c in convs) {
      total += c.messages.length;
      final t = c.updatedAt.toLocal();
      if (t.year == now.year && t.month == now.month && t.day == now.day) {
        today += c.messages.length;
      }
    }
    if (mounted) {
      setState(() {
        _todayMessages = today;
        _totalMessages = total;
        _readingCount = convs.length;
        _diaryCount = diaries.length;
        _musingCount = musings.length;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = context.watch<BackgroundProvider>();
    final darkFg = bg.darkForeground ?? (theme.brightness == Brightness.light);
    final fgColor = darkFg ? const Color(0xFF171717) : Colors.white;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '栖息',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: fgColor,
              ),
            ),
            Text(
              '你的小天地',
              style: theme.textTheme.bodySmall?.copyWith(
                color: fgColor.withValues(alpha: 0.72),
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _card(
            theme,
            icon: Icons.favorite_outline_rounded,
            title: '今日陪伴',
            lines: [
              '今天和 AI 聊了 $_todayMessages 轮，累计 $_totalMessages 轮。',
              '随时回来，它都在。',
            ],
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: Icons.menu_book_outlined,
            title: '阅读角落',
            lines: ['书架上还有 $_readingCount 个对话和书在等你。', '去书架看看今天读点什么。'],
            actionLabel: '去书架',
            onAction: () => widget.onSwitchTab?.call(AppTab.bookshelf),
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: Icons.crop_square_rounded,
            title: '一隅',
            lines: [
              _musingCount > 0 ? '收藏了 $_musingCount 条。' : '还没收藏过，去首页看看它想说什么。',
              '它随口说的话，你觉得值得留下的，都在这。',
            ],
            actionLabel: '去看看',
            onAction: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MusingCornerScreen()),
              );
              _load();
            },
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: Icons.edit_note_outlined,
            title: '日记',
            lines: [
              _diaryCount > 0 ? '已经写了 $_diaryCount 篇。' : '还没写过，聊完天试试看。',
              '每天的一两件小事，AI 用自己的口吻记下来。',
            ],
            actionLabel: '去看看',
            onAction: () async {
              await Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const DiaryScreen()));
              _load();
            },
          ),
        ],
      ),
    );
  }

  Widget _card(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required List<String> lines,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: scheme.onSurface),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onAction, child: Text(actionLabel)),
            ),
          ],
        ],
      ),
    );
  }
}
