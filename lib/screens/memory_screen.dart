import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../config/settings.dart';
import '../services/memory_context.dart';

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
                  if (_raw) _rawView(theme, memory) else ..._blocks(theme, memory),
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
