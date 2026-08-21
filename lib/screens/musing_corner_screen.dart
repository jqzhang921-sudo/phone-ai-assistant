import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/settings.dart';
import '../models/musing_entry.dart';
import '../services/app_providers.dart';
import '../services/storage_service.dart';
import '../services/favorite_picker.dart';
import '../config/app_shape.dart';

/// 一隅：收藏的话。
///
/// 三个来源汇到这里——主页「我想说」、聊天里它说的、聊天里你说的。
/// 前两种都算「它说的」（「我想说」本来就是它写的随想），所以筛选只分两边。
enum _CornerFilter { all, ai, mine }

class MusingCornerScreen extends StatefulWidget {
  const MusingCornerScreen({super.key});

  @override
  State<MusingCornerScreen> createState() => _MusingCornerScreenState();
}

class _MusingCornerScreenState extends State<MusingCornerScreen> {
  _CornerFilter _filter = _CornerFilter.all;
  String _aiName = '';

  bool _picking = false;

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) {
      if (mounted) setState(() => _aiName = s.aiName.trim());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 每次进来都从存储重读一遍。
      //
      // provider 是内存缓存，只有走 App 内的收藏动作才会更新；聊天里
      // `save_to_corner` 工具是直接写 StorageService 的，绕过了 provider——
      // 于是栖息页的计数（直读存储）涨了，这一页却还是旧列表。
      // 备份恢复同理。进页面重读一次最省心。
      context.read<FavoritesProvider>().load();
      _maybePick();
    });
  }

  /// 让沐自己挑几句。
  ///
  /// 触发点放在进这一页时，和「写信」一样不做后台任务——生成要联网、
  /// 人得在前台，国产 ROM 的后台限制也让定时不可靠。冷却在
  /// `shouldPickFavorites()` 里，不然每进一次就烧一次 token。
  Future<void> _maybePick() async {
    if (_picking) return;
    final aiClient = context.read<AiClientProvider>().currentClient;
    if (aiClient == null) return;
    if (!await shouldPickFavorites()) return;
    if (!mounted) return;

    setState(() => _picking = true);
    try {
      final picked = await pickFavorites(aiClient: aiClient);
      // 挑没挑到都记一次，否则挑不出来时每次进来都重试
      await StorageService.setLastFavoritePick(DateTime.now());
      final added = await savePicked(picked);
      if (!mounted) return;
      if (added > 0) {
        await context.read<FavoritesProvider>().load();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${_aiName.isEmpty ? "TA" : _aiName} 留了 $added 句'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (_) {
      // 挑失败不打扰，下次进来再说（这次不记时间戳，留着重试）
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 这句话是从哪儿收来的。
  ///
  /// 不写成「来自 XXX」——这一页每条都是收来的，「来自」是废字。
  /// 左边那个猫/爪印图标只分得出「谁说的」，分不出「我想说」和
  /// 「聊天里说的」，所以这行字不是重复。
  String _sourceLabel(MusingEntry e) => switch (e.source) {
    // 不写「我想说」：那是主页那张卡的名字，卡上是它在用第一人称说话。
    // 搬到这里和「我说的」并排，同一个「我」就指了两个人。
    MusingSource.musing => '${_aiName.isEmpty ? "TA" : _aiName} 的随想',
    MusingSource.ai => '${_aiName.isEmpty ? "TA" : _aiName} 说的',
    MusingSource.user => '我说的',
  };

  /// `dateKey` 是 2026-08-18 这种机器格式，列表里读着硬
  String _dateLabel(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year
        ? '${d.month} 月 ${d.day} 日'
        : '${d.year} 年 ${d.month} 月 ${d.day} 日';
  }

  bool _isMine(MusingEntry e) => e.source == MusingSource.user;

  List<MusingEntry> _apply(List<MusingEntry> all) => switch (_filter) {
    _CornerFilter.all => all,
    _CornerFilter.ai => all.where((e) => !_isMine(e)).toList(),
    _CornerFilter.mine => all.where(_isMine).toList(),
  };

  /// 取消收藏。删除是不可逆的，所以给一条撤销——
  /// 这一页的条目本来就是「特意留下来的话」，误删的代价比别处大。
  Future<void> _delete(MusingEntry entry) async {
    final favs = context.read<FavoritesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await favs.remove(entry.id);
    if (!mounted) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('已取消收藏'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(label: '撤销', onPressed: () => favs.add(entry)),
      ),
    );
  }

  /// 长按写一句备注：为什么留下这句话。原文不动，备注单独存。
  Future<void> _editNote(MusingEntry entry) async {
    final controller = TextEditingController(text: entry.note ?? '');
    final result = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('写一句备注'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(hintText: '为什么想留下这句话'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
    );
    if (result == null || !mounted) return;
    final favs = context.read<FavoritesProvider>();
    await favs.remove(entry.id);
    await favs.add(entry.copyWith(note: result.isEmpty ? null : result));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = context.watch<FavoritesProvider>().entries;
    final shown = _apply(all);
    final mineCount = all.where(_isMine).length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('一隅'),
            // 说明性的那句话从栖息页的卡片挪到这儿。它写得挺好，但每次进
            // 栖息页都读一遍就成了噪音——那一页是入口列表，不是读文案的地方。
            Text(
              '随口说的话，你觉得值得留下的',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // 只有真的存在两种作者时才给筛选——一种作者时三个 chip 是噪音
          if (mineCount > 0 && mineCount < all.length)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  _chip(theme, _CornerFilter.all, '全部 ${all.length}'),
                  const SizedBox(width: 8),
                  _chip(
                    theme,
                    _CornerFilter.ai,
                    '它说的 ${all.length - mineCount}',
                    asset: 'cat',
                  ),
                  const SizedBox(width: 8),
                  _chip(
                    theme,
                    _CornerFilter.mine,
                    '我说的 $mineCount',
                    asset: 'paw',
                  ),
                ],
              ),
            ),
          Expanded(
            child:
                shown.isEmpty
                    ? Center(
                      child: Text(
                        all.isEmpty ? '还没有收藏\n聊天里长按一句话，或点消息下面那朵花' : '这一档还没有',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.7,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      itemCount: shown.length,
                      itemBuilder:
                          (context, index) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _entryCard(theme, shown[index]),
                          ),
                    ),
          ),
        ],
      ),
      bottomNavigationBar:
          all.isEmpty
              ? null
              : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Opacity(
                        opacity: 0.45,
                        child: Image.asset(
                          'assets/icons/flower.png',
                          height: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '点花取消收藏 · 长按可以写一句备注',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
    );
  }

  Widget _chip(
    ThemeData theme,
    _CornerFilter f,
    String label, {
    String? asset,
  }) {
    final scheme = theme.colorScheme;
    final active = _filter == f;
    return GestureDetector(
      onTap: () => setState(() => _filter = f),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color:
              active
                  ? scheme.primaryContainer
                  : scheme.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (asset != null) ...[
              Image.asset(
                'assets/icons/$asset.png',
                height: asset == 'cat' ? 14 : 12,
                color:
                    active
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color:
                    active
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryCard(ThemeData theme, MusingEntry entry) {
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final mine = _isMine(entry);

    // 谁说的一眼能看出来：它说的走白卡 + 主色竖条 + 宋体，
    // 你说的走浅灰底 + 右缩进 + 黑体。和信、日记同一套规则。
    final card = Container(
      padding: EdgeInsets.fromLTRB(mine ? 14 : 16, 14, 10, 14),
      decoration: BoxDecoration(
        color:
            mine
                ? scheme.onSurface.withValues(alpha: 0.035)
                : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: mine ? null : AppShadow.soften(dark),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Opacity(
                opacity: mine ? 0.75 : 1,
                child: Image.asset(
                  mine ? 'assets/icons/paw.png' : 'assets/icons/cat.png',
                  height: mine ? 13 : 15,
                  color: mine ? scheme.onSurfaceVariant : scheme.primary,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                _sourceLabel(entry),
                style: TextStyle(
                  fontSize: mine ? 11.5 : 12,
                  fontWeight: FontWeight.w600,
                  color: mine ? scheme.onSurfaceVariant : scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              // 用 Expanded 独占剩余空间，日期在里面靠左，花才顶得到最右。
              // 写成 Flexible + Spacer 会让两者对半分剩余空间，花就飘到中间。
              Expanded(
                child: Text(
                  _dateLabel(entry.date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 「一起收的」才值得一枚标签——那是你们各自独立挑中了同一句，
              // 是这个功能里唯一产生新信息的地方。它单方面收的只标一行淡字。
              if (entry.savedBy == MusingSavedBy.both)
                Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.11),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '一起收的',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.primary,
                    ),
                  ),
                )
              else if (entry.savedBy == MusingSavedBy.ai)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${_aiName.isEmpty ? "TA" : _aiName} 留的',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // 点花取消收藏。和「收藏」这个动作对称的是同一朵花，
              // 不是一个叉，也温和得多。
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.pill),
                onTap: () => _delete(entry),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Image.asset(
                    'assets/icons/flower.png',
                    height: 16,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.content,
            style: TextStyle(
              fontFamily: mine ? null : 'NotoSerifSC',
              fontSize: mine ? 13.5 : 14.5,
              height: mine ? 1.75 : 1.85,
              color:
                  dark
                      ? scheme.onSurface.withValues(alpha: mine ? 0.75 : 0.9)
                      : (mine
                          ? const Color(0xFF4A423A)
                          : const Color(0xFF2C251F)),
            ),
          ),
          if (entry.note != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                entry.note!,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return GestureDetector(
      onLongPress: () => _editNote(entry),
      child: Padding(
        padding: EdgeInsets.only(left: mine ? 34 : 0),
        child:
            mine
                ? card
                : Stack(
                  children: [
                    card,
                    // 竖条：上下各内缩 20，滚动时连成一条视觉轴
                    Positioned(
                      left: 0,
                      top: 20,
                      bottom: 20,
                      child: Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: const BorderRadius.only(
                            topRight: Radius.circular(3),
                            bottomRight: Radius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
      ),
    );
  }
}
