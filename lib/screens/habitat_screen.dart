import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_tab.dart';
import '../models/letter.dart';
import '../services/app_providers.dart';
import '../services/letter_generator.dart';
import '../services/storage_service.dart';
import 'diary_screen.dart';
import 'letter_screen.dart';
import 'musing_corner_screen.dart';
import '../config/app_shape.dart';

/// 「栖息」页：给用户留的专属空间（陪伴状态 / 阅读角落 / 日记）。
class HabitatScreen extends StatefulWidget {
  final void Function(AppTab tab)? onSwitchTab;

  const HabitatScreen({super.key, this.onSwitchTab});

  @override
  State<HabitatScreen> createState() => _HabitatScreenState();
}

class _HabitatScreenState extends State<HabitatScreen> {
  final _uuid = const Uuid();
  int _todayMessages = 0;
  int _totalMessages = 0;
  int _readingCount = 0;
  int _diaryCount = 0;
  int _musingCount = 0;
  int _letterCount = 0;
  int _unreadLetters = 0;
  bool _writingLetter = false;
  String _letterStatus = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final convs = await StorageService.listConversations();
    final diaries = await StorageService.listDiaryEntries();
    final musings = await StorageService.listFavoritedMusings();
    final letters = await StorageService.listLetters();
    final letterStatus = await letterTriggerStatus();
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
        _letterCount = letters.length;
        _unreadLetters = letters.where((l) => l.isFromAi && !l.read).length;
        _letterStatus = letterStatus;
      });
    }
    if (!mounted) return;
    await _maybeWriteLetter();
  }

  /// 素材够了、也过了冷却期，就让它写一封。
  ///
  /// 检查放在进栖息页时，不做后台任务：信箱就在这一页，用户来这儿本来就是
  /// 看这类东西的，而且生成要联网，人在前台。国产 ROM 的后台限制也让定时
  /// 生成不可能可靠。
  Future<void> _maybeWriteLetter() async {
    if (_writingLetter) return;
    // context 的读取放在任何 await 之前——await 之后这个 State 可能已经销毁。
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;
    if (!await shouldWriteLetter()) return;
    if (!mounted) return;

    setState(() => _writingLetter = true);
    try {
      final content = await generateLetter(aiClient: aiClient);
      // 无论写没写成都记一次尝试。不记的话素材一直堆着，每次进这一页
      // 都会重新触发，白烧 token。
      await StorageService.setLastLetterAttempt(DateTime.now());
      if (content != null) {
        await StorageService.addLetter(
          Letter(
            id: _uuid.v4(),
            author: LetterAuthor.ai,
            content: content,
          ),
        );
        final letters = await StorageService.listLetters();
        if (mounted) {
          setState(() {
            _letterCount = letters.length;
            _unreadLetters =
                letters.where((l) => l.isFromAi && !l.read).length;
          });
        }
      }
    } catch (_) {
      // 写信失败不打扰，下次进来再说（这次不记 attempt，素材留着）
    } finally {
      if (mounted) setState(() => _writingLetter = false);
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
            Consumer<SettingsProvider>(
              builder: (context, sp, _) {
                final serif = sp.settings?.titleSerif ?? true;
                return Text(
                  '栖息',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFamily: serif ? 'NotoSerifSC' : null,
                    fontWeight: FontWeight.w700,
                    color: fgColor,
                  ),
                );
              },
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
            icon: PhosphorIconsRegular.heart,
            title: '今日陪伴',
            lines: [
              '今天和 AI 聊了 $_todayMessages 轮，累计 $_totalMessages 轮。',
              '随时回来，它都在。',
            ],
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: PhosphorIconsRegular.envelopeSimple,
            title: '信',
            highlight: _unreadLetters > 0,
            lines:
                _writingLetter
                    ? ['它正在写一封信…']
                    : _unreadLetters > 0
                    ? [
                      _unreadLetters == 1 ? '有一封信在等你。' : '有 $_unreadLetters 封信在等你。',
                      '不着急，什么时候看都行。',
                    ]
                    : _letterCount > 0
                    ? ['往来 $_letterCount 封。', _letterStatus]
                    : ['还没有信。', _letterStatus],
            actionLabel: '去信箱',
            onAction: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LetterScreen()),
              );
              _load();
            },
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: PhosphorIconsRegular.bookOpen,
            title: '阅读角落',
            lines: ['书架上还有 $_readingCount 个对话和书在等你。', '去书架看看今天读点什么。'],
            actionLabel: '去书架',
            onAction: () => widget.onSwitchTab?.call(AppTab.bookshelf),
          ),
          const SizedBox(height: 14),
          _card(
            theme,
            icon: PhosphorIconsRegular.square,
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
            icon: PhosphorIconsRegular.pencilSimple,
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
    bool highlight = false,
  }) {
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        // 0.72 的白底压不住背景照片：照片一深，卡片就被拉成中灰，正文
        // （onSurfaceVariant #57544F）落在上面只有 3.8:1，达不到 AA 的 4.5:1，
        // 而且照片越花越糊。抬到 0.88 还能透出一点底色，对比度回到 7:1 上下。
        //
        // 同时把写死的 Colors.white 换成 scheme.surface：深色主题下白卡片配
        // 近白的标题字（titleMedium 用 onSurface）本来是看不见的。
        color: scheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color:
              highlight
                  ? scheme.primary.withValues(alpha: 0.5)
                  : scheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: highlight ? scheme.primary : scheme.onSurface,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: highlight ? scheme.primary : null,
                ),
              ),
              if (highlight) ...[
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
            ],
          ),
          const SizedBox(height: 10),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: theme.textTheme.bodyMedium?.copyWith(
                  // 正文不用 onSurfaceVariant：它是给纯色底设计的次级灰，
                  // 叠在半透明卡片上会直接掉到 AA 线下。用 onSurface 压 78%，
                  // 既保留「比标题淡一档」的层次，又不牺牲可读性。
                  color: scheme.onSurface.withValues(alpha: 0.78),
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
