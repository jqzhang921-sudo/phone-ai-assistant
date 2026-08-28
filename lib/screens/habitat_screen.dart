import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_tab.dart';
import '../config/settings.dart';
import '../models/chat_message.dart';
import '../models/letter.dart';
import '../services/app_providers.dart';
import '../services/letter_generator.dart';
import '../widgets/app_surface.dart';
import '../services/storage_service.dart';
import 'diary_screen.dart';
import 'letter_screen.dart';
import 'memory_screen.dart';
import 'musing_corner_screen.dart';
import '../config/app_shape.dart';
import '../config/app_theme.dart';

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
    final midnight = DateTime(now.year, now.month, now.day);
    var today = 0;
    var total = 0;
    // 「今天聊了多少」必须按**每条消息自己的时间戳**数。
    //
    // 原来是看「这段对话今天有没有更新」，然后把整段对话的消息数加进去——
    // 于是今天在一段 538 条的老对话里回一句，就会显示「今天聊了 538 轮」。
    // 之前一直没露馅是因为凑巧：那阵子唯一更新过的对话总共才 2 条。
    //
    // 数的是**用户消息**：一条用户消息开启一轮来回，这才对得上「轮」这个词。
    for (final c in convs) {
      total += c.messages.length;
      for (final m in c.messages) {
        if (m.role != MessageRole.user) continue;
        if (!m.timestamp.toLocal().isBefore(midnight)) today++;
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
          Letter(id: _uuid.v4(), author: LetterAuthor.ai, content: content),
        );
        final letters = await StorageService.listLetters();
        if (mounted) {
          setState(() {
            _letterCount = letters.length;
            _unreadLetters = letters.where((l) => l.isFromAi && !l.read).length;
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 20),
            child: Opacity(
              opacity: 0.5,
              child: Image.asset(
                'assets/icons/mountain.png',
                height: 16,
                color: fgColor,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        // 玻璃卡片要 BackdropFilter 采样身后的背景图，而每项默认套的
        // RepaintBoundary 把两者隔进了不同图层，滚动时会「先透明再模糊」。
        addRepaintBoundaries: false,
        children: [
          _statCard(theme),
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
              asset: 'books',
              title: '阅读角落',
              trailing: _readingCount > 0 ? '$_readingCount 个对话' : null,
              onTap: () => widget.onSwitchTab?.call(AppTab.bookshelf),
            ),
            _RowSpec(
              asset: 'flower',
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
              asset: 'waves',
              title: '日记',
              trailing: _diaryCount > 0 ? '$_diaryCount 篇' : null,
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const DiaryScreen()));
                _load();
              },
            ),
            // 上面三条是「归档」——你存进去的东西。这条不是：它是「它眼里的你」，
            // 每次说话真实带过去的那段。放在一起是因为都属于「它那边的东西」，
            // 但它是唯一一条只读、且内容由系统拼出来的。
            //
            // ⚠️ 图标是随手挑的功能图标（其余三条用的是品牌 png）。要换。
            _RowSpec(
              icon: PhosphorIcons.notebook(PhosphorIconsStyle.regular),
              title: '记忆',
              onTap: () async {
                await Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const MemoryScreen()));
                _load();
              },
            ),
          ]),
          // 触发规则原来整段塞在信的卡片正文里：「再攒 1 点素材……各算 1 点……
          // 另外还有 5 天冷却」——那是规格说明，不是给人看的。现在收成一张
          // 状态卡：一眼看完，底部的空白也顺势填上。
          if (_unreadLetters == 0 && _letterStatus.isNotEmpty) ...[
            const SizedBox(height: 20),
            _nextLetterCard(theme),
          ],
        ],
      ),
    );
  }

  /// 顶部状态卡。数字是「状态」不是入口，所以不做成可点的；
  /// 但它是这一页唯一的总览，值得一张卡把它托住。
  Widget _statCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final parts = <String>[
      if (_diaryCount > 0) '$_diaryCount 篇日记',
      if (_letterCount > 0) '往来 $_letterCount 封信',
      if (_musingCount > 0) '收藏 $_musingCount 条',
    ];
    return AppSurface(
      borderRadius: AppRadius.xlAll,
      child: Stack(
        children: [
          Positioned(
            right: -10,
            bottom: -14,
            child: IgnorePointer(
              child: Opacity(
                opacity: dark ? 0.08 : 0.06,
                child: Image.asset(
                  'assets/mark-simple.png',
                  width: 88,
                  color: dark ? scheme.onSurface : scheme.primary,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$_totalMessages',
                      style: TextStyle(
                        fontFamily: 'NotoSerifSC',
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      // 这个数是 messages.length，即**条数**不是轮数。
                      // 首页对话卡片一直写的是「N 条消息」，两处口径要一致。
                      '条消息',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                if (parts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < parts.length; i++) ...[
                        if (i > 0)
                          Container(
                            width: 1,
                            height: 11,
                            margin: const EdgeInsets.symmetric(horizontal: 10),
                            color: scheme.onSurface.withValues(alpha: 0.12),
                          ),
                        Text(
                          parts[i],
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
                const SizedBox(height: 12),
                Text(
                  _greeting(),
                  style: TextStyle(
                    fontFamily: 'NotoSerifSC',
                    fontSize: 14,
                    height: 1.7,
                    color: scheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 下一封信：素材攒够没、冷却还剩多久。
  ///
  /// ⚠️ 这里说的是**信**，不是日记。日记随时可以记，不需要攒；
  /// 恰恰相反，写日记是攒素材的方式之一（算 1 点）。
  /// 设计稿把这张卡写成「下一篇日记」，是把因果标反了。
  ///
  /// 只做只读展示——`letterTriggerStatus()` 只算得出一句话，算不出
  /// 「素材 3 / 4」那种分子分母，所以不画进度条：画了就是编数字。
  Widget _nextLetterCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: AppShadow.soften(dark),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Image.asset(
              'assets/icons/star.png',
              height: 15,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '下一封信',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _letterStatus,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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

    // 这一页唯一的实色卡。信是有来有往的东西，和下面那三条「归档」
    // 不是一类，靠一整块主色把它单独拎出来。
    //
    // 未读不再靠底色区分（整张已经是实色了），改由标题直接说
    // 「有 N 封信在等你」——一句话比一层色差好认。
    //
    // 全 App 唯一的实色主色块，是「有事发生了」的信号（有信在等你），
    // 所以保留分量。但颜色要跟着背景走——粉色壁纸上一块纯棕是整屏最跑调的
    // 东西，Cleo 的截图里一眼就是它。
    // 底色分三种情况，各自只对一种：
    //
    // - 有背景图 → accent，浅色调的一块，跟着壁纸走
    // - 没背景图 + 深色 → **不能用实心 primary**。深色下 primary 是浅棕
    //   `#D9B48F`，整条亮米色横杠压在 `#171310` 上太扎眼（设计交付原话：
    //   「深色下大面积高明度主色太扎眼」）。换成 primaryContainer。
    // - 没背景图 + 浅色 → `#8B5E34` 白字，是全 App 唯一的实色主色块，不动
    //
    // ⚠️ primaryContainer 的深色档是 `0x2ED9B48F`——**18% 半透明**，
    // 昨天刚坑过书封。直接拿它当实心块，一贴壁纸又是透的，所以要
    // alphaBlend 到 surface 上。
    final accent = context.watch<BackgroundProvider>().backgroundAccent;
    final dark = theme.brightness == Brightness.dark;
    final fill =
        accent ??
        (dark
            ? Color.alphaBlend(scheme.primaryContainer, scheme.surface)
            : scheme.primary);

    // ⚠️ 这里原来写死 `scheme.onPrimary`（白）。底色是运行时从背景图算出来的
    // 强调色，明度锁在 V=0.85 很亮，白字压上去实测只有 1.6–2.6:1，
    // 基本看不见；同一块底换成深墨是 7–11:1。底色是算出来的，前景就不能是
    // 编译期定死的——交给 inkOn 按实际亮度挑。
    final fg = AppTone.of(context).inkOn(fill);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: AppShadow.soften(scheme.brightness == Brightness.dark),
      ),
      child: Material(
        color: fill,
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child:
                      _writingLetter
                          ? SizedBox(
                            width: 17,
                            height: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: fg,
                            ),
                          )
                          : Icon(
                            PhosphorIconsRegular.envelopeSimple,
                            size: 19,
                            color: fg,
                          ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: 'NotoSerifSC',
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                      if (sub != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          sub,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: fg.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  PhosphorIconsRegular.caretRight,
                  size: 16,
                  color: fg.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowGroup(ThemeData theme, List<_RowSpec> specs) {
    final scheme = theme.colorScheme;
    return AppSurface(
      borderRadius: AppRadius.lgAll,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.lg),
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
                      SizedBox(
                        width: 20,
                        child: Center(
                          child:
                              specs[i].asset != null
                                  ? Image.asset(
                                    'assets/icons/${specs[i].asset}.png',
                                    height:
                                        _rowAssetHeight[specs[i].asset] ?? 16,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.65,
                                    ),
                                  )
                                  : Icon(
                                    specs[i].icon,
                                    size: 19,
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.65,
                                    ),
                                  ),
                        ),
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
      ),
    );
  }
}

class _RowSpec {
  /// 二选一：品牌图标给 [asset]，功能图标给 [icon]
  final IconData? icon;
  final String? asset;
  final String title;
  final String? trailing;
  final VoidCallback onTap;

  const _RowSpec({
    this.icon,
    this.asset,
    required this.title,
    this.trailing,
    required this.onTap,
  }) : assert(icon != null || asset != null);
}

/// 品牌图标各自的视觉重量不同，高度不要统一
const _rowAssetHeight = {'books': 15.0, 'flower': 17.0, 'waves': 13.0};
