import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../config/settings.dart';
import '../models/memory_fact.dart';
import '../services/memory_context.dart';
import '../services/storage_service.dart';

/// 「它记着什么」——把每次说话时真实带过去的那段记忆原样摊开。
///
/// 起因：这个 App 的记忆一直是不可见的。用户只能从它答得准不准去反推，
/// 记错了、漏了、或者压根没带上，都看不出来，只能猜。
///
/// 所以这一页**刻意不做美化摘要**：显示的就是 [buildMemoryContext] 的输出
/// 本身。排版视图只把 `##` `**` `-` 这些标记渲染成样式，一个字都不增删；
/// 想看真正发出去的样子，右上角切「原文」。摘要式的展示会重新制造这一页
/// 想解决的问题——你看到的和它拿到的不是同一个东西。
///
/// 之后记忆里加了「它自己写进去的事实」那一层，这一页就是唯一能让用户看见
/// 它写了什么、并且改掉或删掉的地方。**没有这一页，自动写入不该开。**
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  String? _memory;
  String? _error;

  /// 稳定事实单独拿列表，不只是拼好的字符串——这一页要能**改**它们，
  /// 不是只给人看。原文视图里才用拼好的那段。
  List<MemoryFact> _facts = [];
  String _factsRaw = '';
  String _aiName = '';
  String _userName = '';

  /// 排版 / 原文。默认排版——大多数时候要看的是「它记得什么」，
  /// 不是提示词长什么样。
  bool _raw = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 两段分开兜异常，而且都必须兜。
  ///
  /// 这一页原来是「一路 await 到底，setState 收尾」。问题是任何一步抛出来，
  /// setState 就永远不执行，页面卡在转圈上——**看起来像还在加载，其实已经死了**。
  /// 对一个「让你看见真相」的页面来说，这是最糟的失败方式。
  ///
  /// 名字这段单独兜：[AppSettings.load] 里 `settings.dart:102` 有一句
  /// `_secureStorage.read(...)` 没有 try/catch，keystore 出问题它整个抛。
  /// 但名字只是顶部那句说明的点缀，拿不到就不显示，不该拖垮整页。
  Future<void> _load() async {
    var aiName = '';
    var userName = '';
    try {
      final settings = await AppSettings.load();
      aiName = settings.aiName.trim();
      userName = settings.userName.trim();
    } catch (e) {
      debugPrint('[memory] 读设置失败，名字这行不显示：$e');
    }

    var facts = <MemoryFact>[];
    var factsRaw = '';
    try {
      facts = await StorageService.listMemoryFacts();
      factsRaw = await buildStableFacts();
    } catch (e) {
      debugPrint('[memory] 读稳定事实失败：$e');
    }

    String? memory;
    String? error;
    try {
      memory = await buildMemoryContext();
    } catch (e) {
      error = '$e';
    }

    if (!mounted) return;
    setState(() {
      _memory = memory;
      _error = error;
      _facts = facts;
      _factsRaw = factsRaw;
      _aiName = aiName;
      _userName = userName;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final memory = _memory;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('记忆'),
            Text(
              '它这边记着的东西',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          if (memory != null)
            IconButton(
              tooltip: _raw ? '排版显示' : '看原文',
              icon: PhosphorIcon(
                _raw
                    ? PhosphorIcons.article(PhosphorIconsStyle.regular)
                    : PhosphorIcons.code(PhosphorIconsStyle.regular),
              ),
              onPressed: () => setState(() => _raw = !_raw),
            ),
        ],
      ),
      body:
          _error != null
              ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    '读不出记忆：$_error',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              )
              : memory == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _intro(theme, memory),
                  const SizedBox(height: 16),
                  if (_raw)
                    _rawView(theme, '$_factsRaw\n$memory')
                  else ...[
                    ..._factsSection(theme),
                    ..._blocks(theme, memory),
                  ],
                ],
              ),
    );
  }

  /// 顶部说明卡。两件事：这段东西是干嘛的，以及它有多大。
  ///
  /// 字数是刻意露出来的——这段每轮对话都要重发一次，多大就是多少代价。
  /// 藏起来的话，以后往记忆里加东西就没有任何反馈。
  Widget _intro(ThemeData theme, String memory) {
    final scheme = theme.colorScheme;
    final names = [
      if (_aiName.isNotEmpty) '它叫$_aiName',
      if (_userName.isNotEmpty) '它知道你叫$_userName',
    ].join('，');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '每次和它说话，下面这些都会一起带过去。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 6),
          Text(
            '${names.isEmpty ? '' : '$names。'}这段共 ${memory.length} 字，每轮都要重发一次。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 「关于你」——稳定事实那一段。**这一页存在的主要理由就是它。**
  ///
  /// 它自己会往这里写（remember / update_memory / forget），所以这些条目必须
  /// 被看得见、也推翻得掉。看不见的自动写入等于「你不知道它记了什么，
  /// 也拿它没办法」——那正是「自然衰减」最要命的地方，不能换个形式再犯一次。
  ///
  /// 空的时候也要给一句说明，别只留一片白：用户得知道这块是干嘛的、
  /// 以及为什么现在还是空的。
  List<Widget> _factsSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          '关于你',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ];

    if (_facts.isEmpty) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: Text(
            '还是空的。聊着聊着它会把「你是谁」这类事记进来——怎么称呼你、'
            '你在意什么、希望它怎么对你。记进来的都会列在这儿，长按能钉住或删掉。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
        ),
      );
      return out;
    }

    for (final category in MemoryCategory.values) {
      final inCategory = _facts.where((f) => f.category == category).toList();
      if (inCategory.isEmpty) continue;
      out.add(
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: Text(
            category.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
      out.addAll(inCategory.map((f) => _factTile(theme, f)));
    }
    out.add(const SizedBox(height: 22));
    return out;
  }

  Widget _factTile(ThemeData theme, MemoryFact f) {
    final scheme = theme.colorScheme;
    final why = f.why;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.smAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onLongPress: () => _factMenu(f),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (f.pinned)
                      Padding(
                        padding: const EdgeInsets.only(right: 6, top: 3),
                        child: PhosphorIcon(
                          PhosphorIcons.pushPin(PhosphorIconsStyle.fill),
                          size: 13,
                          color: scheme.primary,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        f.content,
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 「谁记的」和「为什么」摆在一起：一条你不认识的事实，
                // 光看内容判断不了它是真的还是它自己编的。
                Text(
                  [
                    f.source == MemorySource.user ? '你说的' : '它自己记的',
                    if (why != null && why.isNotEmpty) why,
                    if (f.edited) '改过',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 长按菜单：钉住 / 删除。
  ///
  /// 钉住之后它改不了也删不了（工具里挡着）。这是给用户的兜底——
  /// 自动写入总会写错，得有个「这条不许动」的说法，否则每次都只能事后补救。
  Future<void> _factMenu(MemoryFact f) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: PhosphorIcon(
                    PhosphorIcons.pushPin(
                      f.pinned
                          ? PhosphorIconsStyle.regular
                          : PhosphorIconsStyle.fill,
                    ),
                  ),
                  title: Text(f.pinned ? '取消钉住' : '钉住（不让它改或删）'),
                  onTap: () => Navigator.of(ctx).pop('pin'),
                ),
                ListTile(
                  leading: PhosphorIcon(
                    PhosphorIcons.trashSimple(PhosphorIconsStyle.regular),
                  ),
                  title: const Text('删掉这条'),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
              ],
            ),
          ),
    );
    if (!mounted || action == null) return;

    if (action == 'pin') {
      await StorageService.updateMemoryFact(f.copyWith(pinned: !f.pinned));
      await _load();
      return;
    }

    // 删除要确认：没有回收站，删了就没了。
    final ok = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('删掉这条记忆？'),
            content: Text('「${f.content}」\n\n删了就没了，它以后不会再知道这件事。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('算了'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删掉'),
              ),
            ],
          ),
    );
    if (ok != true || !mounted) return;
    await StorageService.removeMemoryFact(f.id);
    await _load();
  }

  Widget _rawView(ThemeData theme, String memory) => SelectableText(
    memory,
    style: theme.textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      height: 1.5,
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );

  /// 把那段文本按行渲染。
  ///
  /// `**` 直接去掉不做加粗：那些星号是写给模型看的强调（「只有信例外」之类），
  /// 不是给人看的排版。真想看标记本身，切原文视图。
  List<Widget> _blocks(ThemeData theme, String memory) {
    final scheme = theme.colorScheme;
    final out = <Widget>[];

    for (final line in memory.split('\n')) {
      final text = line.replaceAll('**', '').trim();
      if (text.isEmpty) {
        out.add(const SizedBox(height: 14));
        continue;
      }
      if (text.startsWith('## ')) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              text.substring(3),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
        continue;
      }
      if (text.startsWith('- ')) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7, right: 8),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurfaceVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Expanded(
                  child: SelectableText(
                    text.substring(2),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SelectableText(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return out;
  }
}
