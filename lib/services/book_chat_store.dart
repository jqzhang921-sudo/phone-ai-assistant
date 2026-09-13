import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 单本书的讨论记录。
///
/// ## 为什么要有这个
///
/// 2026-09-07 发现：**从「说本书」进去聊的，首页永远列不出来。**
///
/// 首页那一栏「聊过的书」列的是 [DiscussionGroup]，而 group 只有两个地方会
/// 创建——「多本一起聊」和书架里手动建组。单本讨论存在
/// `book_conversations/book_<bookId>.json`，谁也不去读它。
///
/// 于是出现了这个症状：自己走书架进去的记录都在，那个只用「说本书」的用户
/// **一条都看不见**——而「说本书」恰恰是这个 App 的主路径。
///
/// 记录一直都在，只是没人列。这个类就是来列它的。
class BookChatEntry {
  /// 从文件名还原的书 id（`book_<bookId>.json`）。
  final String bookId;
  final String title;

  /// 最后一条消息的开头，给首页当副标题——比「3 条消息」有用。
  final String preview;

  final DateTime lastAt;
  final int messageCount;

  const BookChatEntry({
    required this.bookId,
    required this.title,
    required this.preview,
    required this.lastAt,
    required this.messageCount,
  });
}

class BookChatStore {
  static Future<Directory> dir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory('${appDir.path}/book_conversations');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static File _fileFor(Directory d, String bookId) =>
      File('${d.path}/book_$bookId.json');

  static Future<File> fileFor(String bookId) async =>
      _fileFor(await dir(), bookId);

  /// 给「说本书」/分享进来这种没有书架身份的书，拼一个稳定的临时 id。
  ///
  /// ## 为什么不用 hashCode
  ///
  /// 原来用 `'adhoc_${title.hashCode}'`。Dart 的 String.hashCode **不保证跨版本
  /// 稳定**，而它要拿去拼对话文件名 `book_<id>.json`——哪天升级 Flutter 换了
  /// 实现，同一本书就接不上旧记录，症状是「记录凭空消失」。用书名本身当 key
  /// 就没这个问题：名字不变，key 就不变。
  ///
  /// 规范化：转小写、只留字母数字和 CJK/假名/谚文，超长截断。这样 key 既是
  /// 稳定标识，也是文件系统安全的文件名片段（不含路径分隔符）。
  static String adhocId(String title) {
    final normalized = title.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9一-鿿㐀-䶿぀-ヿ가-힯]'),
      '',
    );
    final key =
        normalized.length > 40 ? normalized.substring(0, 40) : normalized;
    return 'adhoc_${key.isEmpty ? 'book' : key}';
  }

  /// 列出所有单本讨论，新的在前。
  ///
  /// 一条读不出来就跳过那一条，不整个失败——这是他自己的记录，
  /// 宁可少列一条，也不能因为一个坏文件让整页空白。
  static Future<List<BookChatEntry>> list() async {
    try {
      final d = await dir();
      final entries = <BookChatEntry>[];
      await for (final f in d.list()) {
        if (f is! File || !f.path.endsWith('.json')) continue;
        final entry = _parse(f);
        if (entry != null) entries.add(entry);
      }
      entries.sort((a, b) => b.lastAt.compareTo(a.lastAt));
      return entries;
    } catch (e) {
      debugPrint('[book_chat] 列讨论记录失败：$e');
      return <BookChatEntry>[];
    }
  }

  /// 从文件名还原 bookId：`book_<bookId>.json` 中间那一段。
  ///
  /// 不是这个形状就返回 null。抽出来是因为搜索那边也要认同一个文件名
  /// （见 [BookChatSearch]）——两处各写一遍前缀长度的话，
  /// 哪天命名改了只会有一处跟着改，另一处静静地什么都搜不到。
  static String? bookIdFromFileName(String fileName) {
    if (!fileName.startsWith('book_') || !fileName.endsWith('.json')) {
      return null;
    }
    final id = fileName.substring(5, fileName.length - 5);
    return id.isEmpty ? null : id;
  }

  static BookChatEntry? _parse(File f) {
    try {
      final bookId = bookIdFromFileName(f.uri.pathSegments.last);
      if (bookId == null) return null;

      final data = jsonDecode(f.readAsStringSync());
      if (data is! Map) return null;
      return fromJson(data, bookId: bookId, fallbackAt: f.lastModifiedSync());
    } catch (_) {
      return null;
    }
  }

  /// 解析逻辑单拎出来，好在不碰文件系统的情况下测。
  @visibleForTesting
  static BookChatEntry? fromJson(
    Map data, {
    required String bookId,
    required DateTime fallbackAt,
  }) {
    final messages = data['messages'];
    // 空对话不列——进去看了一眼没说话，不该占一行。
    if (messages is! List || messages.isEmpty) return null;

    String? preview;
    DateTime? lastAt;
    for (final m in messages.reversed) {
      if (m is! Map) continue;
      lastAt ??= DateTime.tryParse(m['timestamp']?.toString() ?? '');
      final c = (m['content']?.toString() ?? '').trim();
      if (preview == null && c.isNotEmpty) {
        preview = c.replaceAll(RegExp(r'\s+'), ' ');
      }
      if (preview != null && lastAt != null) break;
    }
    if (preview == null || preview.isEmpty) return null;

    return BookChatEntry(
      bookId: bookId,
      title: titleOf(data, bookId: bookId),
      preview: preview.length > 60 ? '${preview.substring(0, 60)}…' : preview,
      // 消息上没时间戳就退回文件修改时间：排序总得有个依据。
      lastAt:
          lastAt ??
          DateTime.tryParse(data['updatedAt']?.toString() ?? '') ??
          fallbackAt,
      messageCount: messages.length,
    );
  }

  /// 「这次聊的是《金枝玉叶》。」——[readingPromptFor] 拼系统提示时写进去的。
  static final _titleInPrompt = RegExp(r'这次聊的是《([^《》]{1,60})》');

  /// 这条记录该显示什么名字。
  ///
  /// 早期的记录没把书名写进 `title`（构造时没传），存下来是「新对话」。
  /// 直接退回 bookId 的话，列表上就是一排
  /// `adhoc_584142370` 和 `be3679da-6bb0-…`——**记录是回来了，但认不出是哪本**，
  /// 等于只修了一半。
  ///
  /// 好在书名其实一直在文件里：系统提示的最后一句就是「这次聊的是《X》」。
  /// 从那儿把它捞回来，老记录不用打开也能显示对。
  ///
  /// 公开是因为搜索页也要显示它——搜出来的每条结果都得说清楚是哪本书，
  /// 不然同一句话在哪本书里说的就分不出来了。
  static String titleOf(Map data, {required String bookId}) {
    final stored = (data['title']?.toString() ?? '').trim();
    if (stored.isNotEmpty && stored != '新对话') return stored;

    final prompt = data['systemPrompt']?.toString() ?? '';
    final hit = _titleInPrompt.firstMatch(prompt)?.group(1)?.trim();
    if (hit != null && hit.isNotEmpty) return hit;

    return bookId;
  }

  static Future<void> remove(String bookId) async {
    try {
      final f = await fileFor(bookId);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[book_chat] 删除 $bookId 失败：$e');
    }
  }
}
