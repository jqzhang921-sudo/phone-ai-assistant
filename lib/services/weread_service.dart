import 'dart:convert';
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
      throw Exception(data['errmsg'] ?? '微信读书 API 错误');
    }
    return data is Map<String, dynamic> ? [data] : [];
  }

  /// Fetch books from the user's shelf. Returns only in-progress +
  /// finished books (skips untouched/unread).
  static Future<List<Book>> fetchBooks() async {
    final data = await _call('/shelf/sync');
    if (data.isEmpty) return [];
    final allBooks = (data.first['books'] as List?) ?? [];
    final imported = <Book>[];
    for (final b in allBooks) {
      final finishReading = b['finishReading'] as int? ?? 0;
      final readUpdate = b['readUpdateTime'] as int? ?? 0;
      // Skip books that have never been opened
      if (finishReading == 0 && readUpdate == 0) continue;
      imported.add(Book(
        id: _uuid.v4(),
        title: b['title'] ?? '',
        author: b['author'],
        coverPath: null, // weread covers need auth — skip for now
        status: finishReading == 1 ? ReadingStatus.done : ReadingStatus.reading,
      ));
    }
    return imported;
  }
}
