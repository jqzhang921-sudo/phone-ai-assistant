import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../config/app_shape.dart';
import '../config/settings.dart';
import '../services/document_text.dart';

/// 编辑页交回来的结果。
class PersonaResult {
  /// 新的性格描述。空串 = 清掉，回到默认。
  final String text;

  /// 用户在「要不要也用在所有对话」那个弹窗里点了「用在所有对话」。
  /// 只有单段对话那一侧会是 true。
  final bool alsoGlobal;

  const PersonaResult(this.text, {this.alsoGlobal = false});
}

/// 【TA 的性格】编辑页。全局和单段对话共用这一页。
///
/// ## 为什么不分「详细 / 粗略」两种模式
///
/// 三条：
///
/// 1. **模型不在乎。** 不管分几个字段，最后拼给它的都是一段平文本。
///    结构只帮写的人，不帮读的人。
/// 2. **字段一定会选错。** 定了「性格 / 说话方式 / 偏好 / 性别」，总有人要写
///    「口头禅」「不能碰的话题」。没格子的东西就没人写了——
///    **表单会把没列出来的选项变成不存在的选项。**
/// 3. **它会变成一张表。** 填表的手感是在配置一个产品，而这一栏写的是
///    「TA 是什么样的人」，是这个 App 里少数几个不该像设置项的地方。
///
/// 代替方案是上面那排可点的标签：想细写的人有脚手架，想直接粘文档的人无视它。
/// 一个代码路径、一种存储，也不用管两种模式之间怎么迁移。
///
/// 而且这不是单向门——存的就是一段文本，哪天真要做成表单，数据结构不用动。
class PersonaScreen extends StatefulWidget {
  final String initial;

  /// true = 在设置里编全局的；false = 在某段对话里编那一段的。
  /// 只影响文案，以及存完要不要问「顺便用在所有对话吗」。
  final bool isGlobal;

  /// 全局那边是不是还空着。只有它空着时才问一次——
  /// 用户已经知道有这个开关之后再问，就是每次存都被拦一下。
  final bool globalIsEmpty;

  const PersonaScreen({
    super.key,
    required this.initial,
    this.isGlobal = false,
    this.globalIsEmpty = true,
  });

  @override
  State<PersonaScreen> createState() => _PersonaScreenState();
}

class _PersonaScreenState extends State<PersonaScreen> {
  late final _controller = TextEditingController(text: widget.initial)
    ..addListener(_onChanged);
  final _focusNode = FocusNode();
  bool _importing = false;

  int get _length => _controller.text.characters.length;
  bool get _overLimit => _length > AppSettings.maxPersonaChars;

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 点标签往光标处插一行脚手架。
  ///
  /// 插在**光标处**而不是末尾：用户可能正在中间补一段。前面不是空行就先补个
  /// 换行，不然会黏在上一句尾巴上。
  void _insert(String label) {
    final text = _controller.text;
    final sel = _controller.selection;
    final at = sel.isValid ? sel.start : text.length;
    final before = text.substring(0, at);
    final needsBreak = before.isNotEmpty && !before.endsWith('\n');
    final insert = '${needsBreak ? '\n' : ''}$label：';

    _controller.value = TextEditingValue(
      text: before + insert + text.substring(at),
      selection: TextSelection.collapsed(offset: at + insert.length),
    );
    _focusNode.requestFocus();
  }

  /// 从文件里读文字填进框。**不存文件，存的是抠出来的字。**
  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: DocumentText.extensions,
        withData: true,
      );
      final file = picked?.files.firstOrNull;
      final bytes = file?.bytes;
      if (file == null || bytes == null) return;

      final text = DocumentText.extract(
        name: file.name,
        bytes: Uint8List.fromList(bytes),
      );
      if (!mounted) return;

      // 超了就截断并**明说**截掉多少。默默吞掉的话，用户会以为文档没读全，
      // 而且不知道该删哪儿。
      final chars = text.characters;
      final over = chars.length - AppSettings.maxPersonaChars;
      _controller.text =
          over > 0 ? chars.take(AppSettings.maxPersonaChars).toString() : text;

      if (over > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '读进来了，但超出 ${AppSettings.maxPersonaChars} 字，末尾截掉了 $over 字',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('读不出来：$e')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _save() async {
    final text = _controller.text.trim();
    var alsoGlobal = false;

    // 只在**单段对话** + **全局还空着** 时问一次。
    //
    // 问这一下不是为了省事，是因为有些内容天生该处处生效——怎么称呼、
    // 不想聊的话题，写在只对一段对话有效的地方，换个对话它就不知道了。
    // 而用户根本不知道还有个全局开关，也就不知道自己漏了什么。
    if (!widget.isGlobal && widget.globalIsEmpty && text.isNotEmpty) {
      final answer = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('也用在别的对话里吗？'),
              content: const Text(
                '现在这段性格只对当前这个对话有效，新开的对话还是原来的样子。\n\n'
                '像怎么称呼你、不想聊的话题这种，通常你会想让它处处都算数。\n\n'
                '设置 → TA 的性格 里可以随时改。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('只用在这段'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('用在所有对话'),
                ),
              ],
            ),
      );
      if (answer == null) return; // 点外面关掉 = 还没想好，别替他决定
      alsoGlobal = answer;
    }

    if (!mounted) return;
    Navigator.of(context).pop(PersonaResult(text, alsoGlobal: alsoGlobal));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('TA 的性格'),
            Text(
              widget.isGlobal ? '所有对话都用这个' : '只影响当前这段对话',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _overLimit ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final label in const [
                  '性格',
                  '说话方式',
                  '喜欢什么',
                  '怎么称呼我',
                  '不想聊的',
                ])
                  ActionChip(
                    label: Text(label),
                    labelStyle: theme.textTheme.bodySmall,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _insert(label),
                  ),
                ActionChip(
                  avatar: PhosphorIcon(
                    PhosphorIcons.filePlus(PhosphorIconsStyle.regular),
                    size: 14,
                  ),
                  label: Text(_importing ? '读取中…' : '从文件导入'),
                  labelStyle: theme.textTheme.bodySmall,
                  visualDensity: VisualDensity.compact,
                  onPressed: _importing ? null : _import,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                decoration: InputDecoration(
                  hintText:
                      '想让 TA 是什么样的？\n\n'
                      '比如：说话短一点，别每句都追问；喜欢猫；叫我小名就行。',
                  hintStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    height: 1.55,
                  ),
                  filled: true,
                  fillColor: scheme.surfaceContainerLow,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: AppRadius.mdAll,
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  '$_length / ${AppSettings.maxPersonaChars}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _overLimit ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
                if (_overLimit) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '超出的部分请删掉再保存',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (_controller.text.trim().isNotEmpty)
                  TextButton(
                    onPressed: () {
                      _controller.clear();
                      _focusNode.requestFocus();
                    },
                    child: const Text('清空'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
