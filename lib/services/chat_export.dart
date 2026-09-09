import '../models/chat_message.dart';

/// 把一段讨论排成能直接发出去的文字。
///
/// ## 为什么单独一个文件
///
/// 排版规则（谁说的、要不要带时间、思考带不带、工具调用怎么办）是这个功能
/// 里唯一会出错的地方，也是唯一值得测的地方。混在界面里就只能靠手点。
class ChatExport {
  /// [messages] 已经是用户选中的那些，顺序即原顺序。
  static String format(
    List<ChatMessage> messages, {
    required String bookTitle,
    String? bookAuthor,
    DateTime? exportedAt,
  }) {
    final b = StringBuffer();
    b.writeln('《$bookTitle》');
    if (bookAuthor != null && bookAuthor.trim().isNotEmpty) {
      b.writeln(bookAuthor.trim());
    }
    final at = exportedAt ?? DateTime.now();
    b.writeln('${at.year}-${_two(at.month)}-${_two(at.day)}');
    b.writeln();

    var wrote = false;
    for (final m in messages) {
      final content = m.content.trim();
      // 工具调用那几条没有正文，导出来是空行——跳过。
      if (content.isEmpty) continue;
      // 思考过程不导出。**它是给她看「为什么这么问」的，不是讨论内容本身**，
      // 混进去会把真正说的话冲淡一倍。
      b.writeln('${_who(m.role)}：$content');
      b.writeln();
      wrote = true;
    }
    if (!wrote) return '';
    return b.toString().trimRight();
  }

  /// 用「我 / AI」而不是名字：导出的东西是要发给别人看的，
  /// 别人不知道这个 App 里它叫什么。
  static String _who(MessageRole role) =>
      role == MessageRole.user ? '我' : 'AI';

  static String _two(int n) => n.toString().padLeft(2, '0');
}
