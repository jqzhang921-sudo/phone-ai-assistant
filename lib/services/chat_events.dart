import 'storage_service.dart';

/// 在别处发生、但值得在聊天里留一行的事。
///
/// ## 为什么需要它
///
/// App 里最有分量的几件事都发生在聊天页之外：它写了一封信、记了一篇日记。
/// 而她大部分时间都待在聊天页——于是那些事她**根本不知道发生过**，
/// 除非自己想起来去栖息页翻。
///
/// 主动推送解决的是「不在 App 里的时候」，这一层解决的是「在 App 里但不在
/// 那一页」。两件事，都需要。
///
/// ## 为什么是一行字，不是一条消息
///
/// 做成气泡就成了它在说话——可它并没有开口，只是做了件事。样式跟着日期分割线
/// 走：居中、小、灰、不占地方。**你扫过去知道发生了什么就够了**，
/// 想看细节自己去那一页。
class ChatEvent {
  final DateTime at;

  /// 'letter' | 'diary'。图标和措辞由界面按它决定——服务层不该知道图标长什么样。
  final String kind;

  final String text;

  const ChatEvent({required this.at, required this.kind, required this.text});
}

class ChatEvents {
  /// [since] 之后发生的事，按时间正序。
  ///
  /// 只收**它自己产出的**：信和日记。用户收藏的一隅不算——那是她自己刚做的，
  /// 不需要一行字来通知她。
  ///
  /// 读失败一律当没有：这是一层锦上添花的东西，绝不能因为它让聊天页打不开。
  static Future<List<ChatEvent>> since(DateTime since, {String? aiName}) async {
    final who = (aiName == null || aiName.trim().isEmpty) ? 'TA' : aiName.trim();
    final out = <ChatEvent>[];

    try {
      for (final l in await StorageService.listLetters()) {
        if (l.isFromAi && l.createdAt.isAfter(since)) {
          out.add(
            ChatEvent(at: l.createdAt, kind: 'letter', text: '$who 写了一封信'),
          );
        }
      }
    } catch (_) {}

    try {
      for (final d in await StorageService.listDiaryEntries()) {
        if (d.createdAt.isAfter(since)) {
          out.add(
            ChatEvent(at: d.createdAt, kind: 'diary', text: '$who 记了一篇日记'),
          );
        }
      }
    } catch (_) {}

    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }
}
