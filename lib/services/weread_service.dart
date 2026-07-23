import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../models/book.dart';
import 'package:uuid/uuid.dart';

class WereadStats {
  final int finishedThisMonth;
  final int finishedThisYear;
  final int currentlyReading;
  final int totalOnShelf;

  WereadStats({
    required this.finishedThisMonth,
    required this.finishedThisYear,
    required this.currentlyReading,
    required this.totalOnShelf,
  });
}

class WereadService {
  static const _apiUrl = 'https://i.weread.qq.com/api/agent/gateway';
  static const _keyStorage = 'weread_api_key';
  static final _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static final _uuid = const Uuid();

  static Future<void> saveKey(String key) async =>
      await _secure.write(key: _keyStorage, value: key);

  static Future<String?> getKey() async =>
      await _secure.read(key: _keyStorage);

  static Future<List<Map<String, dynamic>>> _call(
      String api, [Map<String, dynamic>? params]) async {
    final key = await getKey();
    if (key == null) throw Exception('未设置微信读书 API Key');
    final body = <String, dynamic>{
      'api_name': api,
      'skill_version': '1.0.4',
    };
    if (params != null) body.addAll(params);
    final resp = await http.post(Uri.parse(_apiUrl),
        headers: {
          'Authorization': 'Bearer $key',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body));
    final data = jsonDecode(resp.body);
    if (data['errcode'] != null && data['errcode'] != 0) {
      final msg = data['errmsg'] ?? 'unknown';
      print('[weread] API error: $api → $msg (body keys: ${body.keys})');
      throw Exception(msg);
    }
    return data is Map<String, dynamic> ? [data] : [];
  }

  /// Raw shelf data (for stats etc.)
  static Future<List<Map<String, dynamic>>> _rawShelf() async {
    final data = await _call('/shelf/sync');
    if (data.isEmpty) return [];
    return (data.first['books'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  }

  /// Reading stats computed from shelf data
  static Future<WereadStats> fetchReadingStats() async {
    final books = await _rawShelf();
    final now = DateTime.now();
    int thisMonth = 0, thisYear = 0, reading = 0;
    for (final b in books) {
      if (b['finishReading'] == 1) {
        final ts = b['updateTime'] as int? ?? 0;
        final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        if (d.year == now.year) thisYear++;
        if (d.year == now.year && d.month == now.month) thisMonth++;
      }
      if (b['finishReading'] != 1 && (b['readUpdateTime'] ?? 0) > 0) reading++;
    }
    return WereadStats(
      finishedThisMonth: thisMonth,
      finishedThisYear: thisYear,
      currentlyReading: reading,
      totalOnShelf: books.length,
    );
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
      imported.add(Book(
        id: _uuid.v4(),
        title: b['title'] ?? '',
        author: b['author'],
        coverPath: null,
        status: finishReading == 1 ? ReadingStatus.done : ReadingStatus.reading,
        wereadBookId: b['bookId'] as String?,
      ));
    }
    return imported;
  }

  /// Fetch the user's own highlights and bookmarks for a book.
  /// Returns a formatted text block ready to insert into a discussion.
  static Future<String?> fetchHighlights(String wereadBookId) async {
    try {
      final data = await _call('/book/bookmarklist', {'bookId': wereadBookId});
      if (data.isEmpty) return null;
      final chapters = (data.first['chapters'] as List?) ?? [];
      if (chapters.isEmpty) return null;

      final buf = StringBuffer();
      buf.writeln('【以下内容来自微信读书划线/笔记】');
      for (final ch in chapters) {
        final chapterTitle = ch['title'] as String? ?? '';
        final marks = (ch['bookmarks'] as List?) ?? [];
        if (marks.isEmpty) continue;
        if (chapterTitle.isNotEmpty) buf.writeln('\n## $chapterTitle');
        for (final m in marks) {
          final text = m['markText'] ?? m['content'] ?? '';
          if (text.toString().trim().isEmpty) continue;
          buf.writeln('- ${text.toString().trim()}');
        }
      }
      return buf.toString().trim().isNotEmpty ? buf.toString() : null;
    } catch (e) {
      print('[weread] highlights error for $wereadBookId: $e');
      return null;
    }
  }

  /// Fetch the user's own thoughts / reviews for a book.
  static Future<String?> fetchThoughts(String wereadBookId) async {
    try {
      final data =
          await _call('/review/list/mine', {'bookid': wereadBookId});
      if (data.isEmpty) return null;
      final reviews = (data.first['reviews'] as List?) ?? [];
      if (reviews.isEmpty) return null;

      final buf = StringBuffer();
      buf.writeln('【以下内容来自微信读书个人想法】');
      for (final r in reviews) {
        final content = r['review']?['content'] ?? '';
        if (content.toString().trim().isEmpty) continue;
        buf.writeln('- ${content.toString().trim()}');
      }
      return buf.toString().trim().isNotEmpty ? buf.toString() : null;
    } catch (e) {
      print('[weread] thoughts error for $wereadBookId: $e');
      return null;
    }
  }
}
