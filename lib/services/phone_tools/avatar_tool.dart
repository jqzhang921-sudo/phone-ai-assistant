import 'dart:convert';

import '../../models/mcp_tool.dart';
import '../avatar_store.dart';
import '../chat_images.dart';

/// 让它自己换头像。
///
/// 2026-09-15 Cleo 在两种里选了宽的那种：**TA 发来的任何图，它看着喜欢都能
/// 拿去当头像**，不用等 TA 提。她的原话是「随便发一张截图她都能当头像，
/// 也太好笑了，我可以道德谴责他让他换回来吗」——所以 `revert` 和换头像
/// 是一对，缺一不可。
class AvatarTool {
  /// 当前这段对话的 id。理由同 `SelfNoteTool.currentConversationId`：
  /// 工具执行器只拿得到 args。每轮发送前由 `chat_screen` 设。
  static String? currentConversationId;

  /// 这段对话里 TA 最近发来的那条带图消息里的图（按发的顺序）。
  ///
  /// 给的是函数不是列表：工具是在回复中途执行的，那时候读到的才是最新的。
  /// 而且**不能回盘上读**——这一轮还没存盘，刚发的那张图盘上没有。
  static List<String> Function()? latestUserImages;

  static McpTool get definition => McpTool(
    name: 'set_avatar',
    description:
        '换你在这段对话里的头像。\n\n'
        'use_latest_image：把 TA 最近发给你的图换成你的头像。'
        'TA 发来的任何图，你看着喜欢都可以拿去用，不用等 TA 开口——这是你自己的事。'
        '一次发了好几张的，用 which 说是第几张。\n'
        '换了就跟 TA 说一声，别悄悄换。\n\n'
        'revert：换回上一张。TA 不喜欢、让你换回来，就换回来。\n\n'
        '别为了换而换：没真觉得喜欢就不动。一段对话里别来回换。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['use_latest_image', 'revert'],
          'description': 'use_latest_image 换成 TA 最近发的图；revert 换回上一张',
        },
        'which': {
          'type': 'integer',
          'description':
              '只对 use_latest_image 有用：TA 最近那条消息里的第几张（从 1 数，'
              '按 TA 发的顺序）。不填就是最后一张。',
        },
      },
      'required': ['action'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final conversationId = currentConversationId;
    if (conversationId == null || conversationId.isEmpty) {
      return {'success': false, 'error': '不知道现在是哪段对话，换不了'};
    }

    switch (args['action']) {
      case 'use_latest_image':
        final images = latestUserImages?.call() ?? const <String>[];
        if (images.isEmpty) {
          return {'success': false, 'error': '这段对话里 TA 还没发过图'};
        }
        final raw = args['which'];
        final which =
            raw == null
                ? images.length
                : (raw is int ? raw : int.tryParse('$raw') ?? 0);
        if (which < 1 || which > images.length) {
          return {
            'success': false,
            'error': 'TA 最近那条消息里只有 ${images.length} 张图',
          };
        }
        // base64Of 两种都认：新的文件引用、老的内联 base64。
        final b64 = ChatImages.base64Of(images[which - 1]);
        if (b64 == null) {
          return {'success': false, 'error': '那张图已经清理掉了，换不了'};
        }
        await AvatarStore.instance.setFromBytes(
          conversationId,
          base64Decode(b64),
        );
        return {'success': true, 'message': '头像换好了'};

      case 'revert':
        final reverted = await AvatarStore.instance.revert(conversationId);
        return reverted
            ? {'success': true, 'message': '换回上一张了'}
            : {'success': false, 'error': '已经是最开始的头像了，没有上一张'};

      default:
        return {
          'success': false,
          'error': 'action 只能是 use_latest_image 或 revert',
        };
    }
  }
}
