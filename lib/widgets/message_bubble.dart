import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/musing_entry.dart';
import '../services/app_providers.dart';
import '../services/tts_service.dart';
import '../config/app_shape.dart';
import '../config/app_theme.dart';

/// 气泡的底色和字色。
///
/// 抽成纯函数是为了能测。这一处踩过两次，两次都是「字看不见」：
///
/// - 没有背景图时，气泡靠**透出底下的页面底色**成立：深色模式的用户气泡是
///   15% 的浅棕，压在 `#171310` 上出来是一块淡淡的暖影，浅色字读得清。
/// - 一旦贴了背景图，底下不再是一整块纯色，而是一张有明有暗的照片。
///   同样那 15%，在兔子那块亮的地方就是**浅字压浅底**——整句话消失，实测过。
///
/// 所以 [onPhoto] 时气泡必须自己立住底：用玻璃那套基色（跟着背景明暗走，
/// 不跟着 ThemeMode），按 [busyness] 加厚，字色跟着基色配。
/// 结论用测试钉住：合成到纯白和纯黑上都要过 4.5:1。
({Color fill, Color text}) bubbleColors({
  required bool isUser,
  required bool dark,
  required bool onPhoto,
  required bool lightSurface,
  required double busyness,
  required AppTone tone,
  required ColorScheme scheme,
}) {
  if (!onPhoto) {
    // 两侧都留一点透明度，让底下那张徽标透上来——那是全 App 唯一的材质层，
    // 气泡压在上面才有「纸上写字」的层次，实色会把它整片盖掉。
    //
    // 深色透得多一点（水印在暗底上本来就更显），浅色收着些：
    // 白卡在奶白底上本来就只差一点亮度，再透就分不出来了。
    //
    // ⚠️ 只转写死的字面量：`scheme.onSurface` 在建主题时已经转过一遍，
    // 再转一次就是转两次，会跑到别的色相上去。
    return (
      fill: tone.shift(
        isUser
            ? (dark ? const Color(0x26D9B48F) : const Color(0x99E2DACE))
            : (dark ? const Color(0xC7251F1A) : const Color(0xE6FFFFFF)),
      ),
      text:
          isUser
              ? tone.shift(
                dark ? const Color(0xFFEBD9C4) : const Color(0xFF4A3320),
              )
              : (dark
                  ? tone.shift(const Color(0xFFE8DFD4))
                  : scheme.onSurface),
    );
  }

  final base = tone.shift(
    lightSurface ? const Color(0xFFFFFDFB) : const Color(0xFF1A1410),
  );
  // 0.78 起步是「照片再花也压得住」那一档；花的图再加厚。AI 那侧多 4%，
  // 因为它承载的是长正文。
  final alpha = (0.78 + busyness * 0.14 + (isUser ? 0.0 : 0.04)).clamp(0.0, 1.0);
  // 用户那侧掺一点主色，两侧才分得开——只掺 16%，明度基本不动，
  // 上面那条对比度结论不会被它推翻。
  final fill = isUser ? Color.lerp(base, scheme.primary, 0.16)! : base;
  return (
    fill: fill.withValues(alpha: alpha),
    text: tone.shift(
      lightSurface ? const Color(0xFF1A1512) : const Color(0xFFF2EAE0),
    ),
  );
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// 由 `chatDisplayItem` 算好传进来：单条消息自己看不出跟上一条隔了多久。
  final bool showTimestamp;

  /// 收藏要记住这句话出自哪个对话，之后才跳得回来
  final String? conversationId;

  const MessageBubble({
    super.key,
    required this.message,
    this.showTimestamp = true,
    this.conversationId,
  });

  /// 气泡最大宽度。放开了让它占满一行，长句子会横着铺开、读起来费劲。
  static const double _maxBubbleWidth = 262;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == MessageRole.user;
    final isAssistant = message.role == MessageRole.assistant;
    final tts = context.watch<TtsService>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;

    // 颜色全交给 bubbleColors——它自己判断底下是纯色底还是一张照片。
    final bg = context.watch<BackgroundProvider>();
    final glassOn =
        context.watch<SettingsProvider>().settings?.glassSurface ?? false;
    final colors = bubbleColors(
      isUser: isUser,
      dark: dark,
      onPhoto: glassOn && bg.path != null,
      lightSurface: bg.darkForeground ?? !dark,
      busyness: bg.backgroundBusyness,
      tone: AppTone.of(context),
      scheme: scheme,
    );
    final bgColor = colors.fill;
    final textColor = colors.text;

    // 尖角落在靠头像那一侧的**上角**。
    //
    // 设计稿画的是下角（`20px 20px 6px 20px`），但那一版聊天页没有头像，
    // 气泡旁边是空的，尖角朝哪都行。这里头像贴在气泡顶部，尖角朝下就
    // 和头像脱节了——它得指着说话的人。
    const full = Radius.circular(AppRadius.md);
    const tail = Radius.circular(6);
    final radius =
        isUser
            ? const BorderRadius.only(
              topLeft: full,
              topRight: tail,
              bottomLeft: full,
              bottomRight: full,
            )
            : const BorderRadius.only(
              topLeft: tail,
              topRight: full,
              bottomLeft: full,
              bottomRight: full,
            );

    // 它自己开口说的那句，要和「回你的话」看得出区别。
    //
    // 原来主动推送插进来的就是一条普通 assistant 消息，和回复长得一模一样——
    // 于是最该被看见的那件事（**它自己想起了什么**）反而没有任何标记，
    // 用户翻聊天记录根本分不出来。
    //
    // 只加一行小字，不换气泡样式：它说的还是同一种话，只是这句没人问它。
    final isNudge = message.metadata?['nudge'] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isNudge && !isUser)
            Padding(
              padding: const EdgeInsets.only(left: 44, bottom: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    PhosphorIconsFill.butterfly,
                    size: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    // 不写「主动消息」——那是在讲机制。写它做了什么。
                    '它自己想起来的',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          GestureDetector(
            onLongPress: () {
              HapticFeedback.mediumImpact();
              _showCopyMenu(context);
            },
            child: Row(
              mainAxisAlignment:
                  isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUser) _buildAvatar(theme, isUser: false),
                const SizedBox(width: 8),
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(
                      maxWidth: _maxBubbleWidth,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: bgColor,
                      borderRadius: radius,
                      boxShadow: AppShadow.soften(dark),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.images.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _images(message.images),
                          ),
                        if (isUser)
                          Text(
                            message.content,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: textColor,
                            ),
                          )
                        else
                          MarkdownBody(
                            data: message.content,
                            styleSheet: MarkdownStyleSheet(
                              p: theme.textTheme.bodyLarge?.copyWith(
                                color: textColor,
                              ),
                              code: TextStyle(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHigh,
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(
                                  AppRadius.sm,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isUser) const SizedBox(width: 8),
                if (isUser) _buildAvatar(theme, isUser: true),
              ],
            ),
          ),
          if (isAssistant && message.content.trim().isNotEmpty)
            _buildActionRow(context, tts, theme)
          else if (showTimestamp)
            Padding(
              padding: EdgeInsets.only(
                left: isUser ? 0 : 36,
                right: isUser ? 36 : 0,
                top: 4,
              ),
              child: _timestamp(theme),
            ),
        ],
      ),
    );
  }

  /// 当天只报时分；隔天才带上日期。秒没有人看，去掉。
  Widget _timestamp(ThemeData theme) {
    final t = message.timestamp;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    final sameDay =
        t.year == now.year && t.month == now.month && t.day == now.day;
    return Text(
      sameDay ? hm : '${t.month}/${t.day} $hm',
      style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
    );
  }

  void _showCopyMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder:
          (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Builder(
                  builder: (inner) {
                    final fav = context.read<FavoritesProvider>().isFavorited(
                      message.id,
                    );
                    return ListTile(
                      leading: Image.asset(
                        'assets/icons/flower.png',
                        height: 18,
                        color:
                            fav
                                ? Theme.of(ctx).colorScheme.primary
                                : Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                      title: Text(fav ? '取消收藏' : '收进「一隅」'),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _toggleFavorite(context);
                      },
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(PhosphorIconsRegular.copy),
                  title: const Text('复制消息'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('✅ 已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
                if (message.images.isNotEmpty)
                  ListTile(
                    leading: const Icon(PhosphorIconsRegular.image),
                    title: const Text('复制图片'),
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: message.content));
                      Navigator.of(ctx).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ 已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
    );
  }

  /// AI 消息下面那一行：朗读 / 复制 / 时间。
  ///
  /// 复制原来只藏在长按菜单里，一条常用操作不该要长按才找得到；
  /// 长按菜单保留，图片复制还在那儿。
  Widget _buildActionRow(
    BuildContext context,
    TtsService tts,
    ThemeData theme,
  ) {
    final scheme = theme.colorScheme;
    final loading = tts.isLoading(message.id);
    final playing = tts.isPlaying(message.id);
    // 缩进对齐到气泡下方（头像直径 28 + 间距 8）
    return Padding(
      padding: const EdgeInsets.only(left: 36, top: 2),
      child: Row(
        children: [
          _actionButton(
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                await context.read<TtsService>().toggle(
                  message.id,
                  message.content,
                );
              } catch (e) {
                messenger.showSnackBar(SnackBar(content: Text('$e')));
              }
            },
            child:
                loading
                    ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                    : Icon(
                      playing
                          ? PhosphorIconsRegular.stopCircle
                          : PhosphorIconsRegular.speakerHigh,
                      size: 16,
                      color: scheme.primary,
                    ),
          ),
          _FlowerButton(
            favorited: context.watch<FavoritesProvider>().isFavorited(
              message.id,
            ),
            onTap: () => _toggleFavorite(context),
          ),
          _actionButton(
            onTap: () {
              Clipboard.setData(ClipboardData(text: message.content));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('✅ 已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            child: Icon(
              PhosphorIconsRegular.copy,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (showTimestamp) ...[const SizedBox(width: 6), _timestamp(theme)],
        ],
      ),
    );
  }

  /// 收藏 / 取消收藏这一句。
  ///
  /// 存的是一条 [MusingEntry]，带上 messageId 和 conversationId——
  /// 一隅那边要靠它跳回原文，光存内容就找不回来了。
  Future<void> _toggleFavorite(BuildContext context) async {
    final favs = context.read<FavoritesProvider>();
    final messenger = ScaffoldMessenger.of(context);
    if (favs.isFavorited(message.id)) {
      await favs.removeByMessageId(message.id);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(content: Text('已取消收藏'), duration: Duration(seconds: 1)),
      );
      return;
    }
    await favs.add(
      MusingEntry(
        id: const Uuid().v4(),
        date: DateTime.now(),
        content: message.content,
        source:
            message.role == MessageRole.user
                ? MusingSource.user
                : MusingSource.ai,
        messageId: message.id,
        conversationId: conversationId,
      ),
    );
    messenger.clearSnackBars();
    messenger.showSnackBar(
      const SnackBar(content: Text('已收进「一隅」'), duration: Duration(seconds: 1)),
    );
  }

  Widget _actionButton({required VoidCallback onTap, required Widget child}) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(6), child: child),
    );
  }

  /// 品牌图标管「谁」：猫是 AI，爪印是用户。机器小人和通用 user 图标不认人。
  Widget _buildAvatar(ThemeData theme, {required bool isUser}) {
    final scheme = theme.colorScheme;
    return CircleAvatar(
      radius: 14,
      backgroundColor:
          isUser ? scheme.surfaceContainerHighest : scheme.primaryContainer,
      child: Image.asset(
        isUser ? 'assets/icons/paw.png' : 'assets/icons/cat.png',
        height: isUser ? 13 : 15,
        color: isUser ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
      ),
    );
  }

  /// 一条消息里的图。一张就铺满，多张就排成方格。
  ///
  /// 多张仍然**挤在一个气泡里**，不拆成几条：它们是一次发出去的，
  /// 拆开看就成了几件不相干的事，和发给模型时挤在同一条消息里是一个道理。
  Widget _images(List<String> images) {
    if (images.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Image.memory(
          base64Decode(images.first),
          height: 160,
          width: double.infinity,
          fit: BoxFit.cover,
        ),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final image in images)
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.memory(
              base64Decode(image),
              width: 92,
              height: 92,
              fit: BoxFit.cover,
            ),
          ),
      ],
    );
  }
}

/// 收藏用的花。点击时做 200ms 的 1.0 → 1.25 → 1.0，
/// 单纯变色太轻，弹一下才像「留住了」。
class _FlowerButton extends StatefulWidget {
  final bool favorited;
  final VoidCallback onTap;

  const _FlowerButton({required this.favorited, required this.onTap});

  @override
  State<_FlowerButton> createState() => _FlowerButtonState();
}

class _FlowerButtonState extends State<_FlowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.25), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1.0), weight: 1),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () {
        _controller.forward(from: 0);
        widget.onTap();
      },
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: ScaleTransition(
          scale: _scale,
          child: Image.asset(
            'assets/icons/flower.png',
            height: 16,
            color: widget.favorited ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
