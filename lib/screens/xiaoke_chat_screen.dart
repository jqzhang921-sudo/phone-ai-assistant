import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/chat_message.dart';
import '../services/avatar_store.dart';
import '../services/xiaoke_channel.dart';
import '../widgets/avatar_sheet.dart';
import '../widgets/message_bubble.dart';

/// 「小克」：跟电脑上那个 Claude Code 会话直接聊，像 Telegram 那样。
///
/// 和主聊天页**不是一回事**：这里发的不经过 App 里的模型，没有人设、
/// 没有记忆、没有工具。原理见 [XiaokeChannel]。
class XiaokeChatScreen extends StatefulWidget {
  const XiaokeChatScreen({super.key});

  @override
  State<XiaokeChatScreen> createState() => _XiaokeChatScreenState();
}

class _XiaokeChatScreenState extends State<XiaokeChatScreen> {
  /// 小克的头像也能换，走和对话头像同一套，key 固定。
  static const avatarKey = 'xiaoke';

  final _input = TextEditingController();
  final _channel = XiaokeChannel.instance;

  @override
  void initState() {
    super.initState();
    _channel.load();
    AvatarStore.instance.load(avatarKey);
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    HapticFeedback.lightImpact();
    await _channel.send(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: _channel,
      builder: (context, _) {
        final messages = _channel.messages;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                GestureDetector(
                  onTap: () => showAvatarSheet(context, avatarKey),
                  child: ListenableBuilder(
                    listenable: AvatarStore.instance,
                    builder: (context, _) {
                      final file = AvatarStore.instance.currentFile(avatarKey);
                      return CircleAvatar(
                        radius: 17,
                        backgroundColor: scheme.primaryContainer,
                        backgroundImage:
                            file == null
                                ? null
                                : ResizeImage(FileImage(file), width: 128),
                        child:
                            file == null
                                ? Text(
                                  '克',
                                  style: TextStyle(
                                    color: scheme.onPrimaryContainer,
                                  ),
                                )
                                : null,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '小克',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _channel.online ? '电脑那边连着' : '电脑那边没连上，发的先存着',
                      style: TextStyle(
                        fontSize: 11,
                        color:
                            _channel.online
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '连接信息',
                icon: const Icon(PhosphorIconsRegular.plugs),
                onPressed: _showConnectionInfo,
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child:
                    messages.isEmpty
                        ? Center(
                          child: Text(
                            '在这儿发的消息会直接到电脑上的小克那里，\n不经过 App 里的模型。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        )
                        : ListView.builder(
                          // 倒着排，打开就在最新那条。理由同主聊天页。
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: messages.length,
                          itemBuilder:
                              (context, i) =>
                                  _item(messages[messages.length - 1 - i]),
                        ),
              ),
              _inputBar(theme),
            ],
          ),
        );
      },
    );
  }

  Widget _item(XiaokeMessage m) {
    final bubble = MessageBubble(
      key: ValueKey(m.id),
      message: ChatMessage(
        id: m.id,
        role: m.fromMe ? MessageRole.user : MessageRole.assistant,
        content: m.text,
        timestamp: m.ts,
      ),
      // 头像按这个 key 取，见 [avatarKey]。
      conversationId: avatarKey,
    );
    if (!m.fromMe || m.delivered) return bubble;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        bubble,
        Padding(
          padding: const EdgeInsets.only(right: 44, bottom: 8),
          child: Text(
            '还没送到，电脑那边连上就送过去',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _inputBar(ThemeData theme) {
    final canSend = _input.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '给小克发消息…',
                  filled: true,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            IconButton(
              onPressed: canSend ? _send : null,
              icon: const Icon(PhosphorIconsRegular.paperPlaneRight),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showConnectionInfo() async {
    final addresses = await XiaokeChannel.localAddresses();
    if (!mounted) return;
    final port = _channel.boundPort ?? XiaokeChannel.defaultPort;
    final token = _channel.token;
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('连接信息'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_channel.online ? '电脑那边连着。' : '电脑那边还没连上。'),
                  const SizedBox(height: 12),
                  const Text('手机地址（电脑那边要填的）：'),
                  if (addresses.isEmpty) const Text('（没查到，看看是不是没连网）'),
                  for (final a in addresses)
                    SelectableText('ws://$a:$port${XiaokeChannel.path}'),
                  const SizedBox(height: 12),
                  const Text('连接码：'),
                  SelectableText(token ?? '（服务还没开起来）'),
                  const SizedBox(height: 8),
                  Text(
                    '连接码就是钥匙：拿到它、又跟手机在同一个网络里的人，'
                    '能收到你在这儿发的消息，也能冒充小克回你。别发到别处。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (token != null)
                TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: token));
                    Navigator.pop(ctx);
                  },
                  child: const Text('复制连接码'),
                ),
              TextButton(
                onPressed: () async {
                  await _channel.resetToken();
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('换一个'),
              ),
            ],
          ),
    );
  }
}
