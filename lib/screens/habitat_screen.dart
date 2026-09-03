import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../config/app_tab.dart';
import '../config/settings.dart';
import '../models/chat_message.dart';
import '../services/app_providers.dart';
import '../services/letter_schedule.dart';
import '../services/self_notes.dart';
import '../services/small_things.dart';
import '../widgets/app_surface.dart';
import '../services/storage_service.dart';
import 'days_screen.dart';
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
  int _todayMessages = 0;
  int _totalMessages = 0;
  int _readingCount = 0;
  int _diaryCount = 0;
  int _musingCount = 0;
  int _letterCount = 0;
  int _unreadLetters = 0;
  bool _writingLetter = false;
  String _letterStatus = '';

  /// 它给自己留的便签。
  ///
  /// ⚠️ 措辞上有个分寸：规矩里明写了「不用告诉 TA 你会回来问，那样等于先许一个
  /// 承诺」。贴出来看似跟这条打架，其实不冲突——**这不是它给你的承诺，
  /// 是它给自己的便条，你碰巧看得见**。所以标题写「它记着的事」，
  /// 不写「它会问你的事」；到点了也不催，只是纸条还在那儿。
  List<SelfNote> _notes = const [];

  /// 她自己要做的小事。和便签贴在同一块板上，但**是两套生命周期**：
  /// 便签会自动过期，小事只会因为她勾了才离开。
  List<SmallThing> _smallThings = const [];

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
    final letterStatus = await LetterSchedule.statusLine();
    final settings = await AppSettings.load();
    final now = DateTime.now();
    final notes = await SelfNoteStore.pending(now);
    final smallThings = await SmallThingStore.pending();
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
        _notes = notes;
        _smallThings = smallThings;
        _aiName = settings.aiName;
      });
    }
    if (!mounted) return;
    await _maybeWriteLetter();
  }

  /// 素材够了就**排一封**，到点了才真写。
  ///
  /// 原来是进这一页当场生成。改成延时有两个理由，第二个更实际：
  ///
  /// 1. 当场出信像自动售货机——按一下掉一封
  /// 2. **「我刚写完一封信」这句话永远说不出口**：信是在她用 App 的时候生成
  ///    的，那会儿主动说话的门槛（离上次聊天满三小时）必然挡着；等能说了，
  ///    「刚写完」早就不成立了
  ///
  /// 真正写的动作在 [LetterSchedule.writeIfDue]，前台后台共用：后台醒了后台写，
  /// 后台被 ROM 掐了就等她下次进这一页补上。谁先到谁写，另一边再调是空跑。
  Future<void> _maybeWriteLetter() async {
    if (_writingLetter) return;
    // context 的读取放在任何 await 之前——await 之后这个 State 可能已经销毁。
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;

    await LetterSchedule.scheduleIfReady();

    setState(() => _writingLetter = true);
    try {
      if (await LetterSchedule.writeIfDue(aiClient: aiClient)) {
        final letters = await StorageService.listLetters();
        if (mounted) {
          setState(() {
            _letterCount = letters.length;
            _unreadLetters = letters.where((l) => l.isFromAi && !l.read).length;
          });
        }
      }
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
          // 小事板排在信下面、归档那组上面：它和信一样是「正在发生的」，
          // 而下面三条是归档——你存进去的东西。
          _noteBoard(theme),
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
            // 「日子」是时间轴：上面四条按类别看存下的东西，这条按天翻——
            // 日记、信、消息、一隅全摊在一张月历上。
            _RowSpec(
              icon: PhosphorIcons.calendarBlank(PhosphorIconsStyle.regular),
              title: '日子',
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DaysScreen()),
                );
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
    //
    // ⚠️ 贴壁纸时这里原来走 `backgroundAccent`（从图里取的强调色），那是
    // 「纯棕跑调」的补丁。色相旋转（AppTone）已经把整套 scheme 转到壁纸色相
    // 上了，primary 本身就跟着壁纸走，绕过它没必要了。而 accent 的明度锁在
    // V=0.85，是浅浅的一块，撑不起「全 App 唯一的实色卡」这个分量。
    // → 换回旋转后的 primary，三种情况收成两种，只按深浅分：
    //
    // - 深色 → **不能用实心 primary**。深色档的 primary 是高明度色（原棕系
    //   是 `#D9B48F`），整条亮横杠压在 `#171310` 上太扎眼（设计交付原话：
    //   「深色下大面积高明度主色太扎眼」）。换成 primaryContainer。
    // - 浅色 → 旋转后的 primary 实心块（原棕系是 `#8B5E34`）
    //
    // ⚠️ primaryContainer 的深色档是 `0x2ED9B48F`——**18% 半透明**，
    // 昨天刚坑过书封。直接拿它当实心块，一贴壁纸又是透的，所以要
    // alphaBlend 到 surface 上。
    final dark = theme.brightness == Brightness.dark;
    final fill = dark
        ? Color.alphaBlend(scheme.primaryContainer, scheme.surface)
        : scheme.primary;

    // ⚠️ 这里原来写死 `scheme.onPrimary`（白）。底色现在是旋转后的 primary，
    // 色相跟着壁纸走、亮度不固定——绿和黄那几档旋转出来明显更亮，白字压上去
    // 就不够。底色是算出来的，前景就不能是编译期定死的，交给 inkOn 按实际
    // 亮度挑。
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

  /// 「小事」板：它给自己留的便签，和她自己要做的事，贴在一块板上。
  ///
  /// ## 两种纸，两套规矩
  ///
  /// 便签会自动过期（「饭做好了吗」问晚了就没意义），小事**绝不自动消失**
  /// （那不叫过期，叫丢东西）。共用一块板没问题，共用生命周期会出最难发现的
  /// 那种 bug，所以存储是彻底分开的两套。
  ///
  /// ## 区分靠形状，不靠颜色
  ///
  /// **小事带勾选框，便签不带。** 四种纸色已经拿去做「不像复印的」了，而且
  /// 颜色在深色模式和色盲眼里都不可靠；勾选框在任何情况下都读得出来，
  /// 而且它本身就说明了那张纸能拿它怎么办。
  Widget _noteBoard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final tone = AppTone.of(context);
    final empty = _notes.isEmpty && _smallThings.isEmpty;

    return AppSurface(
      borderRadius: AppRadius.lgAll,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  PhosphorIconsRegular.pushPin,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  // 板上现在有两个人的东西，所以标题不再挂它一个人的名字。
                  // 也没叫「角落」——「一隅」已经是那个词了，撞名字会让两个
                  // 地方都变模糊。
                  '小事',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                // 加一件她自己的。它也能替她贴（add_small_thing），
                // 但「我自己想记一件」不该非得先开口说话。
                InkWell(
                  onTap: _addSmallThing,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      PhosphorIconsRegular.plus,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (empty) ...[
              const SizedBox(height: 6),
              Text(
                '想起什么要做的，点上面的加号贴一张。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
            const SizedBox(height: 10),
            // 固定两列，不按内容自然换行。
            //
            // 原来是 Wrap + maxWidth 200：文字一长就各占一整行，两张便签就吃掉
            // 三分之一屏，四张会把下面的入口全推下去。两列之后同样四张封顶
            // 只有两行，高度减半——而这一块的作用是「扫一眼知道它记着什么」，
            // 不是让人细读，占屏比读全更要紧。
            LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - 10) / 2;
                var i = 0;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    // 小事排前面：那是她要做的，比「它惦记着什么」更该先看到。
                    for (final s in _smallThings)
                      SizedBox(
                        width: w,
                        child: _smallThingSlip(theme, tone, s, i++),
                      ),
                    for (final n in _notes)
                      SizedBox(width: w, child: _noteSlip(theme, tone, n, i++)),
                  ],
                );
              },
            ),
            if (!empty) ...[
              const SizedBox(height: 8),
              Text(
                '点方框表示做完了 · 长按撕掉',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 几种纸色。
  ///
  /// 都压在很低的彩度上（明度 0.93 上下）：这是纸，不是标签。饱和的便利贴色
  /// 会把这一块从「他随手记的」变成「一个提醒功能」，而且四张凑在一起会喧宾
  /// 夺主——这一页的主角是那封信。
  ///
  /// ⚠️ 颜色在这里**不承载含义**，只是不让四张纸看着像复印的。
  /// 以后要是把用户的待办也贴上来，「谁写的」得靠**形状**区分（比如带勾选框），
  /// 不能靠颜色——颜色已经被用掉了，而且色盲和深色模式下都不可靠。
  static const _paperTones = [
    Color(0xFFF3E7CE), // 米
    Color(0xFFEFE4DC), // 灰粉
    Color(0xFFE4EAE0), // 灰绿
    Color(0xFFE6E7EF), // 灰蓝
  ];

  /// 一张纸条。
  ///
  /// 歪一点点是故意的：正着码成一列就成了待办清单，那是任务的样子。
  /// 角度按 index 交替，很小（±1.2°）——大了就成了装饰。
  Widget _noteSlip(ThemeData theme, AppTone tone, SelfNote n, int index) {
    final scheme = theme.colorScheme;
    // 纸条底色写死再过 tone.shift：跟着主题转，默认棕下不变。
    // 不用 scheme 里的现成色，是因为它们都是「界面」的颜色，
    // 而这里要的是一张纸压在界面上。
    //
    // 四种纸色轮着来。**按 id 的哈希取，不按 index**——按 index 的话，
    // 撕掉一张，剩下几张的颜色会集体跳一格，像是它把便签重写了一遍。
    // 认哪张纸是靠颜色的，颜色跟着 id 走才稳。
    final paper = tone.shift(_paperTones[n.id.hashCode.abs() % _paperTones.length]);
    final ink = tone.shift(const Color(0xFF3D3529));
    final due = n.isDue(DateTime.now());

    return Transform.rotate(
      angle: (index.isEven ? 1.2 : -1.2) * 3.1415926 / 180,
      child: GestureDetector(
        onLongPress: () async {
          await SelfNoteStore.remove(n.id);
          if (mounted) _load();
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.16),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                n.about,
                // 截到四行。它写便签是写给自己看的，有时会带一整句来龙去脉
                // （「她说吃完饭歇会儿再去，拖延着还没去」），全展开就把这一块
                // 撑成一屏。四行足够认出是哪件事，认不出来的那部分不重要。
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'NotoSerifSC',
                  fontSize: 12.5,
                  height: 1.45,
                  color: ink,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                // 到点了也不催，只说纸条还在。催是索取，这一页不做那件事。
                due ? '就这会儿' : _untilText(n.dueAt),
                style: TextStyle(
                  fontSize: 10.5,
                  color: ink.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一张她自己的纸条。和便签同一种纸，多一个勾选框。
  ///
  /// 勾掉 ≠ 删掉：只记一个时间，纸从板上下来但东西留一周。误触一下就永久丢
  /// 一件事，代价和收益完全不成比例。所以还给一次撤销。
  Widget _smallThingSlip(
    ThemeData theme,
    AppTone tone,
    SmallThing s,
    int index,
  ) {
    final scheme = theme.colorScheme;
    final paper = tone.shift(
      _paperTones[s.id.hashCode.abs() % _paperTones.length],
    );
    final ink = tone.shift(const Color(0xFF3D3529));

    return Transform.rotate(
      angle: (index.isEven ? 1.2 : -1.2) * 3.1415926 / 180,
      child: GestureDetector(
        onLongPress: () async {
          await SmallThingStore.remove(s.id);
          if (mounted) _load();
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: paper,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withValues(alpha: 0.16),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 勾选框是「这张纸是谁的」唯一可靠的标记——颜色不算数。
              // 单独做成可点的区域，避免长按撕掉和点击勾选打架。
              InkWell(
                onTap: () => _markSmallThingDone(s),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.only(right: 7, top: 1, bottom: 2),
                  child: Container(
                    width: 13,
                    height: 13,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: ink.withValues(alpha: 0.5),
                        width: 1.4,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'NotoSerifSC',
                        fontSize: 12.5,
                        height: 1.45,
                        color: ink,
                      ),
                    ),
                    if (s.dueAt != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        _dueText(s.dueAt!),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: ink.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _markSmallThingDone(SmallThing s) async {
    await SmallThingStore.markDone(s.id);
    if (!mounted) return;
    _load();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('做完了'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await SmallThingStore.undone(s.id);
            if (mounted) _load();
          },
        ),
      ),
    );
  }

  /// 截止那行。**过期了也只是陈述，不催**——「过期」两个字本身就够重了，
  /// 再加感叹号或者红色就成了指责。
  String _dueText(DateTime due) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(due.year, due.month, due.day).difference(today).inDays;
    if (d < 0) return '${-d} 天前就该做了';
    if (d == 0) return '今天';
    if (d == 1) return '明天';
    if (d < 7) return '$d 天后';
    return '${due.month} 月 ${due.day} 日';
  }

  Future<void> _addSmallThing() async {
    final controller = TextEditingController();
    DateTime? due;

    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, set) => AlertDialog(
                  title: const Text('记一件小事'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: controller,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: '要做什么',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => Navigator.of(ctx).pop(true),
                      ),
                      const SizedBox(height: 12),
                      // 截止是可选的。默认不选——替她安排一个日期是多事，
                      // 而且大部分小事本来就没有期限。
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final e in <(String, DateTime?)>[
                            ('不设', null),
                            ('今天', DateTime.now()),
                            (
                              '明天',
                              DateTime.now().add(const Duration(days: 1)),
                            ),
                            (
                              '这周内',
                              DateTime.now().add(const Duration(days: 7)),
                            ),
                          ])
                            ChoiceChip(
                              label: Text(e.$1),
                              selected:
                                  due == null
                                      ? e.$2 == null
                                      : e.$2 != null &&
                                          due!.difference(e.$2!).inHours.abs() <
                                              2,
                              onSelected: (_) => set(() => due = e.$2),
                            ),
                        ],
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('算了'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('贴上'),
                    ),
                  ],
                ),
          ),
    );

    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || text.isEmpty) return;

    await SmallThingStore.add(
      SmallThing(
        id: const Uuid().v4(),
        text: text,
        createdAt: DateTime.now(),
        dueAt: due,
      ),
    );
    if (mounted) _load();
  }

  String _untilText(DateTime due) {
    final d = due.difference(DateTime.now());
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟后';
    if (d.inHours < 24) return '${d.inHours} 小时后';
        author: SmallThingAuthor.user,
    return '明天';
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
