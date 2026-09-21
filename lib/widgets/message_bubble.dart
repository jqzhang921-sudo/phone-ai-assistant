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
import '../services/stickers.dart';
import '../services/voice_message.dart';
import '../services/avatar_store.dart';
import 'avatar_sheet.dart';
import 'chat_image_stack.dart';
import 'voice_bubble.dart';
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
              : (dark ? tone.shift(const Color(0xFFE8DFD4)) : scheme.onSurface),
    );
  }

  final base = tone.shift(
    lightSurface ? const Color(0xFFFFFDFB) : const Color(0xFF1A1410),
  );
  // 0.78 起步是「照片再花也压得住」那一档；花的图再加厚。AI 那侧多 4%，
  // 因为它承载的是长正文。
  final alpha = (0.78 + busyness * 0.14 + (isUser ? 0.0 : 0.04)).clamp(
    0.0,
    1.0,
  );
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

  /// 这条是不是一组的头一条。
  ///
  /// ## 为什么头像给的是「头一条」，不是 Telegram 的「最后一条」
  ///
  /// Telegram 把头像放在一组的**底部**——它的头像贴着气泡下沿。这里不一样：
  /// 头像贴的是气泡**顶部**，所以同样的「指着说话的人」这个规则，落到这套
  /// 布局上就是给第一条。照抄位置会得到一个指着空气的头像。借的是规则，
  /// 不是坐标。
  ///
  /// ⚠️ 2026-09-21 起**尖角没有了**（四角统一 20，理由见 build 里那段）。
  /// 这个标记现在只管头像和间距。
  final bool isGroupStart;

  /// 这条是不是一组的最后一条。决定下面留 14 还是 3，以及操作按钮出不出现。
  final bool isGroupEnd;

  /// 收藏要记住这句话出自哪个对话，之后才跳得回来
  final String? conversationId;

  const MessageBubble({
    super.key,
    required this.message,
    this.showTimestamp = true,
    this.isGroupStart = true,
    this.isGroupEnd = true,
    this.conversationId,
  });

  /// 气泡最大宽度。放开了让它占满一行，长句子会横着铺开、读起来费劲。
  static const double _maxBubbleWidth = 262;

  /// 头像直径。组里后面几条要留同宽的空位来对齐，所以这个数得有名字——
  /// 两处写 28 迟早会分叉。
  static const double _avatarSize = 28;

  /// 气泡内的行高。
  ///
  /// 主题里 `bodyLarge` 是 **1.75**——那是给随笔、长文、读书讨论那种要一段
  /// 一段读下去的地方定的，松是对的。但聊天气泡里，15px 的字撑到 26px 行高，
  /// 两行就把气泡顶得老高，**看起来像文字在气泡里游泳**。
  ///
  /// 1.42 是 Telegram 那种贴合度：中文两行仍然分得清，气泡却收回到刚好裹住
  /// 文字。只在这里覆盖，不动主题——别处的松是有理由的。
  static const double _bubbleLineHeight = 1.42;

  @override
  Widget build(BuildContext context) {
    // 它在聊天里看了一眼屏幕：截图挂在一条 user 消息上（模型才看得到图，见
    // chat_screen 的 _appendGlanceShot）。但那不是她说的话——画在它那一边，
    // 字也不显示。
    final isGlanceShot = message.metadata?['glanceShot'] == true;
    // 一张表情。图是打包进 App 的资源，消息里只记一个 key，见 [Sticker]。
    final sticker = stickerOf(message.metadata?['sticker'] as String?);
    final isUser = message.role == MessageRole.user && !isGlanceShot;
    final voice = VoiceMessage.fromMetadata(message.metadata);
    final isAssistant = message.role == MessageRole.assistant;
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

    // 四角一样圆，**没有尖角**。
    //
    // 2026-09-21 Cleo 提的。这里原来把靠头像那一侧的上角从 20 收到 6，
    // 当作「这一串的开头」的标记。去掉的理由是它冗余：「这句是谁说的」
    // 已经被说了三遍——头像、左右位置、底色深浅，尖角是第四遍。
    // 而它又是「聊天软件」最强的那个符号，和这个 App 想要的安静调子打架
    // （和主页那摞会话卡片是同一类问题）。
    //
    // 成组不靠它：同一个人连着说的间隔 3、换人 14（见下面那段 padding），
    // 那个差别比一个 6 像素的角明显得多。
    const radius = BorderRadius.all(Radius.circular(AppRadius.md));

    // 它自己开口说的那句，要和「回你的话」看得出区别。
    //
    // 原来主动推送插进来的就是一条普通 assistant 消息，和回复长得一模一样——
    // 于是最该被看见的那件事（**它自己想起了什么**）反而没有任何标记，
    // 用户翻聊天记录根本分不出来。
    //
    // 只加一行小字，不换气泡样式：它说的还是同一种话，只是这句没人问它。
    final isNudge = message.metadata?['nudge'] == true;

    // 它在后台看了一眼她的屏幕。图就是截到的那张，一定要标出来——
    // 「看过一定留痕」是答应她的，痕迹认不出来等于没留。
    final isGlance = message.metadata?['glance'] == true || isGlanceShot;

    // 气泡里有没有东西要画。图不算——图画在气泡外面。
    // 截图消息的字是写给模型的说明，不画。
    final hasBody =
        voice != null ||
        // 表情消息的字不画：它自己发的那条正文是空的；她发的那条正文是
        // `[表情：困了]`，那句是写给模型看的（否则它不知道收到了什么），
        // 显示出来只会是一行多余的方括号。
        (!isGlanceShot &&
            sticker == null &&
            message.content.trim().isNotEmpty) ||
        (isAssistant && (message.thinking?.trim().isNotEmpty ?? false));

    return Padding(
      // 组内 3，组间 14。**这一个数字是「成组」看起来成立的主要原因**——
      // 三条各隔 14 是三次发言，各隔 3 是一口气说的三句。
      padding: EdgeInsets.only(bottom: isGroupEnd ? 14 : 3),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if ((isNudge || isGlance) && !isUser)
            Padding(
              padding: const EdgeInsets.only(left: 44, bottom: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isGlance
                        ? PhosphorIconsFill.eye
                        : PhosphorIconsFill.butterfly,
                    size: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    // 不写「主动消息」——那是在讲机制。写它做了什么。
                    isGlance ? '它看了一眼你的屏幕' : '它自己想起来的',
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
                // 组里后面几条不再画头像，但要留出同宽的空位，
                // 否则第二条就会往左挪 36，整串歪掉。
                if (!isUser)
                  isGroupStart
                      ? _buildAvatar(theme, isUser: false)
                      : const SizedBox(width: _avatarSize),
                const SizedBox(width: 8),
                Flexible(
                  // 图和字**分开放**：图在上面单独立着，字在下面自己一个气泡。
                  //
                  // 原来图塞在气泡里、字跟在图下面。Cleo 2026-09-14 说要
                  // 分开——图裹在一块底色里，卡片的边、露出来的那几张都被
                  // 糊成一片，微信也是图单独放。
                  //
                  // 只发了图、一个字没打的，就只有图，不再画一个空气泡。
                  child: Column(
                    crossAxisAlignment:
                        isUser
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                    children: [
                      // 表情画在气泡外面，和图一样——贴纸裹在一块底色里就不是贴纸了。
                      if (sticker != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: hasBody ? 4 : 0),
                          child: Image.asset(
                            sticker.asset,
                            width: 132,
                            height: 132,
                            // 像素画：插值会把它糊成一团。
                            filterQuality: FilterQuality.none,
                          ),
                        ),
                      if (message.images.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(bottom: hasBody ? 4 : 0),
                          child: ChatImageGallery(
                            images: message.images,
                            alignEnd: isUser,
                          ),
                        ),
                      if (hasBody)
                        Container(
                          constraints: const BoxConstraints(
                            maxWidth: _maxBubbleWidth,
                          ),
                          // 13/8，原来是 16/12。
                          //
                          // 竖直方向减得比水平多：气泡「胖」主要胖在上下——左右
                          // 留白少了，长句子会顶到圆角上，反而挤。
                          padding: const EdgeInsets.symmetric(
                            horizontal: 13,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: bgColor,
                            borderRadius: radius,
                            boxShadow: AppShadow.soften(dark),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isAssistant &&
                                  (message.thinking?.trim().isNotEmpty ??
                                      false))
                                _ThinkingBlock(
                                  text: message.thinking!,
                                  color: textColor,
                                  // 正文还没来 = 它还在想，这时候默认摊开，
                                  // 不然屏幕上只有一个空气泡，看着像卡住了。
                                  startExpanded: message.content.trim().isEmpty,
                                ),
                              // 语音消息：只画语音条，**不画文字**。
                              //
                              // 文字和语音摆在一起，语音就白发了——眼睛比耳朵快，
                              // 你会直接读完，不会点播放。而它选择用说的，
                              // 多半是想让你听见语气。文字在长按菜单里。
                              if (voice != null)
                                VoiceBubble(
                                  voice: voice,
                                  messageId: message.id,
                                  textColor: textColor,
                                )
                              else if (isUser)
                                Text(
                                  message.content,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: textColor,
                                    height: _bubbleLineHeight,
                                  ),
                                )
                              else
                                MarkdownBody(
                                  data: message.content,
                                  styleSheet: MarkdownStyleSheet(
                                    // 段落之间也收一点：默认 8 是按文档排的，
                                    // 气泡里两段之间不需要那么远。
                                    blockSpacing: 6,
                                    p: theme.textTheme.bodyLarge?.copyWith(
                                      color: textColor,
                                      height: _bubbleLineHeight,
                                    ),
                                    code: TextStyle(
                                      backgroundColor:
                                          theme
                                              .colorScheme
                                              .surfaceContainerHigh,
                                      fontFamily: 'monospace',
                                      fontSize: 13,
                                    ),
                                    codeblockDecoration: BoxDecoration(
                                      color:
                                          theme
                                              .colorScheme
                                              .surfaceContainerHigh,
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.sm,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (isUser) const SizedBox(width: 8),
                if (isUser)
                  isGroupStart
                      ? _buildAvatar(theme, isUser: true)
                      : const SizedBox(width: _avatarSize),
              ],
            ),
          ),
          // 🔇 气泡下面不再挂那一排「朗读 / 收藏 / 复制」。
          //
          // 那三个动作是**偶尔才用**的，却是整页重复度最高的东西——每组回复
          // 出现一次。微信、Telegram 都不放常驻动作按钮，全在长按里。
          //
          // 现在统一收进 [_showCopyMenu]（长按气泡）。那个菜单本来就有收藏和
          // 复制，只缺朗读，补上就齐了。
          //
          // 去掉之后聊天页从「一个 App」变回「一段对话」。
          if (showTimestamp)
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
                // 语音消息的文字藏在这儿——这是看到它说了什么的唯一入口。
                if (VoiceMessage.fromMetadata(message.metadata) != null &&
                    message.content.trim().isNotEmpty)
                  ListTile(
                    leading: const Icon(PhosphorIconsRegular.textAa),
                    title: const Text('转文字'),
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _showTranscript(context);
                    },
                  ),
                // 朗读原来在气泡下面那一排常驻按钮里，现在收进来了。
                // 只有它说的话才有得读；已经是语音的那条不用再念一遍。
                if (message.role == MessageRole.assistant &&
                    VoiceMessage.fromMetadata(message.metadata) == null &&
                    message.content.trim().isNotEmpty)
                  Builder(
                    builder: (inner) {
                      final tts = inner.watch<TtsService>();
                      final playing = tts.isPlaying(message.id);
                      final loading = tts.isLoading(message.id);
                      return ListTile(
                        leading:
                            loading
                                ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : Icon(
                                  playing
                                      ? PhosphorIconsRegular.stopCircle
                                      : PhosphorIconsRegular.speakerHigh,
                                ),
                        title: Text(playing ? '停止朗读' : '朗读'),
                        onTap: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          Navigator.of(ctx).pop();
                          try {
                            await context.read<TtsService>().toggle(
                              message.id,
                              message.content,
                            );
                          } catch (e) {
                            messenger.showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                        },
                      );
                    },
                  ),
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
  /// 语音转文字：把它说的话摊开给你看。
  ///
  /// 单开一张，不是塞回气泡里——**气泡一旦长出文字，下次你就不会再点播放了**。
  /// 这是「想看的时候能看」，不是「默认就摆着」。
  void _showTranscript(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder:
          (ctx) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: SingleChildScrollView(
              child: Text(
                message.content,
                style: const TextStyle(fontSize: 15, height: 1.8),
              ),
            ),
          ),
    );
  }

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

  /// 品牌图标管「谁」：猫是 AI，爪印是用户。机器小人和通用 user 图标不认人。
  Widget _buildAvatar(ThemeData theme, {required bool isUser}) {
    final scheme = theme.colorScheme;
    final fallback = CircleAvatar(
      radius: _avatarSize / 2,
      backgroundColor:
          isUser ? scheme.surfaceContainerHighest : scheme.primaryContainer,
      child: Image.asset(
        isUser ? 'assets/icons/paw.png' : 'assets/icons/cat.png',
        height: isUser ? 13 : 15,
        color: isUser ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
      ),
    );
    // 你的头像全局一张，它的按对话记，见 [AvatarStore]；没换过就是爪印和猫。
    // 两边都听着 store：换了之后上面几条气泡当场跟着变。
    final key = isUser ? AvatarStore.userKey : conversationId;
    if (key == null) return fallback;
    final avatar = ListenableBuilder(
      listenable: AvatarStore.instance,
      builder: (context, _) {
        final file = AvatarStore.instance.currentFile(key);
        if (file == null) return fallback;
        return CircleAvatar(
          radius: _avatarSize / 2,
          backgroundImage: ResizeImage(FileImage(file), width: 96),
        );
      },
    );
    // 点自己的头像换你的头像。它的头像不在这儿换、在顶栏换：
    // 气泡里的头像密密一排，点它的很容易误触。
    if (!isUser) return avatar;
    return Builder(
      builder:
          (context) => GestureDetector(
            onTap: () => showAvatarSheet(context, AvatarStore.userKey),
            child: avatar,
          ),
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

/// 气泡里那一小块思考过程。
///
/// 默认收起来，只留一行「想了想」。摊开是灰的、比正文小一号——它是草稿，
/// 不该跟说出口的话抢注意力。
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({
    required this.text,
    required this.color,
    this.startExpanded = false,
  });

  final String text;
  final Color color;
  final bool startExpanded;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool? _override;

  /// 用户点过就听用户的；没点过就跟着 [startExpanded] 走——这样思考还在流的
  /// 时候是摊开的，正文一到自动收起，而一旦她自己点开，就不再被收回去。
  bool get _expanded => _override ?? widget.startExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = widget.color.withValues(alpha: 0.55);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _override = !_expanded),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _expanded
                      ? PhosphorIcons.caretDown()
                      : PhosphorIcons.caretRight(),
                  size: 12,
                  color: dim,
                ),
                const SizedBox(width: 4),
                Text(
                  '想了想',
                  style: theme.textTheme.labelSmall?.copyWith(color: dim),
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 16),
              child: Text(
                widget.text.trim(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: dim,
                  height: 1.45,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
