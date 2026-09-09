import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import 'package:uuid/uuid.dart';

class WereadService {
  static const _apiUrl = 'https://i.weread.qq.com/api/agent/gateway';
  static const _keyStorage = 'weread_api_key';
  static final _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static final _uuid = const Uuid();

  static Future<void> saveKey(String key) async =>
      await _secure.write(key: _keyStorage, value: key);

  static Future<String?> getKey() async => await _secure.read(key: _keyStorage);

  /// 配没配过 key。没配的时候调用方该**静默跳过**，不该弹错——
  /// 划线是锦上添花，不是必需品。
  static Future<bool> get hasKey async {
    final k = await getKey();
    return k != null && k.isNotEmpty;
  }

  static Future<List<Map<String, dynamic>>> _call(
    String api, [
    Map<String, dynamic>? params,
  ]) async {
    final key = await getKey();
    if (key == null) throw Exception('未设置微信读书 API Key');
    final body = <String, dynamic>{'api_name': api, 'skill_version': '1.0.4'};
    if (params != null) body.addAll(params);
    final resp = await http.post(
      Uri.parse(_apiUrl),
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    final data = jsonDecode(resp.body);
    if (data['errcode'] != null && data['errcode'] != 0) {
      final msg = data['errmsg'] ?? 'unknown';
      debugPrint('[weread] API error: $api → $msg (body keys: ${body.keys})');
      throw Exception(msg);
    }
    return data is Map<String, dynamic> ? [data] : [];
  }

  /// 书架原始数据。
  static Future<List<Map<String, dynamic>>> _rawShelf() async {
    final data = await _call('/shelf/sync');
    if (data.isEmpty) return [];
    return (data.first['books'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Fetch books from the user's shelf. Returns only in-progress +
  /// finished books (skips untouched/unread).
  static Future<List<Book>> fetchBooks() async {
    final allBooks = await _rawShelf();
    final imported = <Book>[];
    for (final b in allBooks) {
      final finishReading = b['finishReading'] as int? ?? 0;
      final readUpdate = b['readUpdateTime'] as int? ?? 0;
      if (finishReading == 0 && readUpdate == 0) continue;
      imported.add(
        Book(
          id: _uuid.v4(),
          title: b['title'] ?? '',
          author: b['author'],
          coverPath: null,
          status:
              finishReading == 1 ? ReadingStatus.done : ReadingStatus.reading,
          wereadBookId: b['bookId'] as String?,
        ),
      );
    }
    return imported;
  }

  /// 他划的，一条一行。
  ///
  /// ## 为什么要这个，而不是只有 [fetchHighlights]
  ///
  /// 拼好的那个字符串是给**聊天气泡**用的——照原样显示给他看。但要把划线
  /// 送进 system prompt（见 `reader_traces.dart`）就得先做长度预算：划得多
  /// 的书有几百条，全塞进去能把人设和历史一起挤出缓存。做预算必须拿到列表
  /// 本身，从拼好的字符串里再切一遍是自找麻烦。
  ///
  /// 出错返回空表而不是抛：调用方全都是「有就用、没有就算」。
  static Future<List<String>> highlightLines(String wereadBookId) async {
    try {
      final data = await _call('/book/bookmarklist', {'bookId': wereadBookId});
      if (data.isEmpty) return const [];
      final updated = (data.first['updated'] as List?) ?? [];
      return _lines(updated, (m) => m['markText']);
    } catch (e) {
      debugPrint('[weread] highlights error for $wereadBookId: $e');
      return const [];
    }
  }

  /// 他自己写的想法/书评，一条一行。
  static Future<List<String>> thoughtLines(String wereadBookId) async {
    try {
      final data = await _call('/review/list/mine', {'bookid': wereadBookId});
      if (data.isEmpty) return const [];
      final reviews = (data.first['reviews'] as List?) ?? [];
      return _lines(reviews, (r) => r['review']?['content']);
    } catch (e) {
      debugPrint('[weread] thoughts error for $wereadBookId: $e');
      return const [];
    }
  }

  /// 两个接口回来的形状不同，取值的那一下不同，其余（去空、压空白、去重）
  /// 完全一样——所以只在取值上分叉。
  static List<String> _lines(List raw, dynamic Function(Map) pluck) {
    final out = <String>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final text = (pluck(e)?.toString() ?? '')
          .replaceAll(RegExp(r'[ \t]+'), ' ')
          .trim();
      if (text.isEmpty) continue;
      if (!seen.add(text)) continue;
      out.add(text);
    }
    return out;
  }

  /// Fetch the user's own highlights and bookmarks for a book.
  /// Returns a formatted text block ready to insert into a discussion.
  static Future<String?> fetchHighlights(String wereadBookId) async {
    final lines = await highlightLines(wereadBookId);
    if (lines.isEmpty) return null;
    final buf = StringBuffer();
    buf.writeln('【以下内容来自微信读书划线/笔记】');
    for (final l in lines) {
      buf.writeln('- $l');
    }
    return buf.toString();
  }

  /// Fetch the user's own thoughts / reviews for a book.
  static Future<String?> fetchThoughts(String wereadBookId) async {
    final lines = await thoughtLines(wereadBookId);
    if (lines.isEmpty) return null;
    final buf = StringBuffer();
    buf.writeln('【以下内容来自微信读书个人想法】');
    for (final l in lines) {
      buf.writeln('- $l');
    }
    return buf.toString();
  }
}
