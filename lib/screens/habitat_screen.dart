import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/app_tab.dart';
import '../services/app_providers.dart';
import '../services/storage_service.dart';

/// 「栖息」页：给用户留的专属空间（陪伴状态 / 阅读角落 / 灵感占位）。
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final convs = await StorageService.listConversations();
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
            icon: Icons.auto_awesome_outlined,
            title: '灵感占位',
            lines: ['这里以后可以放：心情记录、专注计时、纪念日、每日一句…', '想放什么，随时告诉我。'],
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
