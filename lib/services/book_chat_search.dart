import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'book_chat_store.dart';

/// 一条能被搜到的消息。
///
/// **只收用户和 AI 说的话。** 工具调用的参数和结果、系统提示这些不给人看的
/// 东西不进索引——搜出来一条他从没在屏幕上见过的 JSON，比搜不到更让人
/// 摸不着头脑：他不知道那是哪儿来的，也点不进去看。
class SearchableMessage {
  final bool isUser;
  final String content;
  final DateTime? at;

  const SearchableMessage({
    required this.isUser,
    required this.content,
    this.at,
  });
}

/// 一场讨论的全部内容，摊开来准备被搜。
///
/// 连消息正文一起读进来，是为了让过滤整个发生在内存里：查询要跟着输入
/// 即时出结果，每敲一个字重读一遍目录是不行的（见 [BookChatSearch.load]）。
class SearchableChat {
  final String bookId;
  final String title;
  final List<SearchableMessage> messages;
  final DateTime lastAt;

  const SearchableChat({
    required this.bookId,
    required this.title,
    required this.messages,
    required this.lastAt,
  });
}

/// 一条命中。片段已经裁好，直接拿去显示。
class ChatSearchHit {
  final String bookId;
  final String title;
  final bool isUser;

  /// 命中处前后各留一段，单行放得下。
  final String snippet;
  final DateTime? at;

  const ChatSearchHit({
    required this.bookId,
    required this.title,
    required this.isUser,
    required this.snippet,
    this.at,
  });
}

/// 在讨论记录里搜内容。
///
/// ## 为什么搜的是消息，不是书名
///
/// 首页那一栏是按书排的，能认出自己那本书的前提是**记得书名**。而想找的时候
/// 往往反过来：记得的是某次聊到的一句话（「上次说的那个什么效应来着」），
/// 书名早忘了。这时候按书排的列表一点忙都帮不上，只能一本本点进去翻。
///
/// 书名照样搜得到（写在每条结果上面），但主路径是「记得一句话，找回那场对话」。
class BookChatSearch {
  const BookChatSearch._();

  /// 一场讨论最多贡献几条结果。
  ///
  /// 不设的话，一个高频词会让某一本书的结果铺满整屏，别的书全被挤到看不见的
  /// 地方。3 条够他认出「是这一场」，剩下的进去自己翻。
  static const _perChat = 3;

  /// 结果总数上限。再多他也不会往下拉了。
  static const _max = 80;

  /// 片段前后各留多少字。前面少留一点：命中词靠前更好读，
  /// 而且前面那段通常只是铺垫。
  static const _before = 18;
  static const _after = 56;

  /// 把所有讨论记录读进内存。
  ///
  /// **一次读完，不是每敲一个字读一遍。** 记录是几十个 JSON，全读进来也就
  /// 几百毫秒，之后每次过滤都是纯内存比较，可以跟着输入即时出结果。
  /// 反过来做的话，输入框里会有肉眼可见的卡顿，而且毫无意义——
  /// 这一页开着的时候，没有谁会去改这些文件。
  static Future<List<SearchableChat>> load() async {
    try {
      final d = await BookChatStore.dir();
      final out = <SearchableChat>[];
      await for (final f in d.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        final chat = _parse(f);
        if (chat != null) out.add(chat);
      }
      out.sort((a, b) => b.lastAt.compareTo(a.lastAt));
      return out;
    } catch (e) {
      debugPrint('[book_chat] 读搜索索引失败：$e');
      return <SearchableChat>[];
    }
  }

  /// 一个坏文件不该让整页打不开，跳过它就是了——记录是他自己的，
  /// 宁可少搜到一场，也不能因为一个文件读不出来就整页空白。
  static SearchableChat? _parse(File f) {
    try {
      final bookId = BookChatStore.bookIdFromFileName(f.uri.pathSegments.last);
      if (bookId == null) return null;

      final data = jsonDecode(f.readAsStringSync());
      if (data is! Map) return null;

      final raw = data['messages'];
      if (raw is! List) return null;

      final messages = <SearchableMessage>[];
      for (final m in raw) {
        if (m is! Map) continue;
        final role = m['role']?.toString() ?? '';
        if (role != 'user' && role != 'assistant') continue;
        final content = (m['content']?.toString() ?? '').trim();
        if (content.isEmpty) continue;
        messages.add(
          SearchableMessage(
            isUser: role == 'user',
            content: content,
            at: DateTime.tryParse(m['timestamp']?.toString() ?? ''),
          ),
        );
      }
      if (messages.isEmpty) return null;

      return SearchableChat(
        bookId: bookId,
        title: BookChatStore.titleOf(data, bookId: bookId),
        messages: messages,
        // 对话自己的 updatedAt 最准；老文件没有就退回最后一条消息的时间，
        // 再没有就用文件修改时间——排序总得有个依据。
        lastAt:
            DateTime.tryParse(data['updatedAt']?.toString() ?? '') ??
            messages.last.at ??
            f.lastModifiedSync(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 把查询切成词。
  ///
  /// 只在空白处切。中文没有空格，整串就是一个词——这恰好是对的：
  /// 「金枝玉叶」该搜到的就是这四个字连在一起的地方，不是「金」「枝」
  /// 各自出现的地方。
  static List<String> terms(String query) => query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  /// 搜。每个词都得出现才算命中。
  ///
  /// 用「与」不用「或」：多打一个词是**收窄**的意思。按「或」算的话，
  /// 他多打一个字结果反而变多，接着只能靠人眼再筛一遍——那搜索就白做了。
  static List<ChatSearchHit> run(
    List<SearchableChat> chats,
    List<String> terms, {
    int perChat = _perChat,
    int max = _max,
  }) {
    if (terms.isEmpty) return const [];

    final hits = <ChatSearchHit>[];
    for (final chat in chats) {
      var taken = 0;
      // 一场讨论里从后往前找：最近说的那句，通常才是他要找的那句。
      for (final m in chat.messages.reversed) {
        if (taken >= perChat) break;
        final idx = _firstHit(m.content, terms);
        if (idx < 0) continue;
        hits.add(
          ChatSearchHit(
            bookId: chat.bookId,
            title: chat.title,
            isUser: m.isUser,
            snippet: _snippet(m.content, idx),
            at: m.at,
          ),
        );
        taken++;
        if (hits.length >= max) return hits;
      }
    }
    return hits;
  }

  /// 最早出现的那一处，返回**原文**里的下标（片段按它裁）。
  ///
  /// 有一个词没出现就整体不算命中。
  static int _firstHit(String content, List<String> terms) {
    final lower = content.toLowerCase();
    var best = -1;
    for (final t in terms) {
      final i = lower.indexOf(t);
      if (i < 0) return -1;
      if (best < 0 || i < best) best = i;
    }
    return best;
  }

  /// 裁出命中处周围的一小段。
  ///
  /// 换行和连续空白在这儿压成一个空格——列表里每条只占一行，不压的话
  /// 会看到一段忽宽忽窄的空白，而且真正的内容被顶出去看不见了。
  static String _snippet(String content, int idx) {
    var a = (idx - _before).clamp(0, content.length);
    var b = (idx + _after).clamp(0, content.length);

    // 别把一个代理对切成两半——emoji 会变成两个乱码方块。
    // Dart 的字符串是 UTF-16，下标落在代理对中间是可能的。
    if (a > 0 && _isLowSurrogate(content.codeUnitAt(a))) a--;
    if (b < content.length && _isLowSurrogate(content.codeUnitAt(b))) b++;

    final body = content.substring(a, b).replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${a > 0 ? '…' : ''}$body${b < content.length ? '…' : ''}';
  }

  static bool _isLowSurrogate(int codeUnit) =>
      codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;
}
