import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_tab.dart';
import '../config/settings.dart';
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

  /// 设置里填的「TA 叫什么」。填了就用名字，不填就把句子改写成不需要代词的。
  ///
  /// 原来文案里到处是「它」——中文的「它」指向物件或动物，读起来像在说一个
  /// 摆件，和这一页想要的陪伴感是打架的。
  String _aiName = '';

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
    final settings = await AppSettings.load();
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
        _aiName = settings.aiName;
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
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _statLine(theme),
          const SizedBox(height: 20),
          _letterEntry(theme),
          const SizedBox(height: 16),
          // 其余三项压成一组紧凑的行。
          //
          // 原来五张等高卡片竖着码，一屏只放得下两张半，而且每张的正文和右下角
          // 按钮之间都有一大块空白——五张加起来就是半屏的浪费。这一页真正需要
          // 被看见的只有「有没有未读的信」，其余都是入口，一行足够。
          _rowGroup(theme, [
            _RowSpec(
              icon: PhosphorIconsRegular.bookOpen,
              title: '阅读角落',
              trailing: _readingCount > 0 ? '$_readingCount 个对话' : null,
              onTap: () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            _RowSpec(
              icon: PhosphorIconsRegular.quotes,
              title: '一隅',
              trailing: _musingCount > 0 ? '收藏 $_musingCount 条' : null,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MusingCornerScreen()),
                );
                _load();
              },
            ),
            _RowSpec(
              icon: PhosphorIconsRegular.pencilSimple,
              title: '日记',
              trailing: _diaryCount > 0 ? '$_diaryCount 篇' : null,
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const DiaryScreen()));
                _load();
              },
            ),
          ]),
          // 触发规则挪到这儿，一行淡字。原来整段塞在信的卡片正文里：
          // 「再攒 1 点素材……各算 1 点……另外还有 5 天冷却」——那是规格说明，
          // 不是给人看的。
          if (_unreadLetters == 0 && _letterStatus.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              _letterStatus,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                height: 1.6,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 顶部状态：数字是「状态」不是入口，一行就够，不该占一整张卡。
  Widget _statLine(ThemeData theme) {
    final scheme = theme.colorScheme;
    final parts = <String>[
      if (_diaryCount > 0) '$_diaryCount 篇日记',
      if (_letterCount > 0) '往来 $_letterCount 封信',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$_totalMessages',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '轮对话',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
            if (parts.isNotEmpty)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '· ${parts.join(' · ')}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _greeting(),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  /// 填了名字就用名字，没填就改写成不需要代词的句子。
  ///
  /// 原来这里是「随时回来，它都在」。中文的「它」指向物件或动物，读起来像在
  /// 说一个摆件，和这一页想要的陪伴感是打架的。设置里已经有「TA 叫什么」，
  /// 用得上。
  String _greeting() {
    if (_todayMessages > 0) return '今天聊了 $_todayMessages 轮。';
    if (_aiName.isEmpty) return '今天还没聊过，随时回来。';
    return '今天还没聊过。随时回来，$_aiName 在。';
  }

  /// 信是这一页唯一有时效性的东西，所以只有它保持卡片形态。
  /// 有未读时用赤陶色升上来，没有未读就退回和其余三项一样的中性底。
  Widget _letterEntry(ThemeData theme) {
    final scheme = theme.colorScheme;
    final unread = _unreadLetters > 0;

    final String title;
    final String? sub;
    if (_writingLetter) {
      title = '正在写一封信…';
      sub = null;
    } else if (unread) {
      title = _unreadLetters == 1 ? '有一封信在等你' : '有 $_unreadLetters 封信在等你';
      sub = '不着急，什么时候看都行';
    } else if (_letterCount > 0) {
      title = '信';
      sub = '往来 $_letterCount 封';
    } else {
      title = '信';
      sub = '还没有信';
    }

    final fg = unread ? scheme.onPrimaryContainer : scheme.onSurface;

    return Material(
      color:
          unread
              ? scheme.primaryContainer.withValues(alpha: 0.94)
              : scheme.surface.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const LetterScreen()));
          _load();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              if (_writingLetter)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: fg.withValues(alpha: 0.6),
                  ),
                )
              else
                Icon(
                  PhosphorIconsRegular.envelopeSimple,
                  size: 19,
                  color: unread ? fg : fg.withValues(alpha: 0.65),
                ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    if (sub != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                PhosphorIconsRegular.caretRight,
                size: 16,
                color: fg.withValues(alpha: 0.55),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rowGroup(ThemeData theme, List<_RowSpec> specs) {
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < specs.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.only(left: 44),
                child: Divider(
                  height: 0.5,
                  thickness: 0.5,
                  color: scheme.onSurface.withValues(alpha: 0.08),
                ),
              ),
            InkWell(
              onTap: specs[i].onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      specs[i].icon,
                      size: 19,
                      color: scheme.onSurface.withValues(alpha: 0.65),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        specs[i].title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                    if (specs[i].trailing != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          specs[i].trailing!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    Icon(
                      PhosphorIconsRegular.caretRight,
                      size: 15,
                      color: scheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RowSpec {
  final IconData icon;
  final String title;
  final String? trailing;
  final VoidCallback onTap;

  const _RowSpec({
    required this.icon,
    required this.title,
    this.trailing,
    required this.onTap,
  });
}
