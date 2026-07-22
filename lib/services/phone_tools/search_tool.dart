import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../models/mcp_tool.dart';

class SearchTool {
  static const _defaultKey = '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';
  static const _storageKey = 'tavily_api_key';
  static const _endpoint = 'https://api.tavily.com/search';

  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Read the active Tavily key: secure storage → fallback to default.
  static Future<String> _apiKey() async {
    final stored = await _secureStorage.read(key: _storageKey);
    if (stored != null && stored.isNotEmpty) return stored;
    // First run — migrate the default into secure storage
    await _secureStorage.write(key: _storageKey, value: _defaultKey);
    return _defaultKey;
  }

  /// Save a new key (called from settings UI).
  static Future<void> saveKey(String key) async {
    await _secureStorage.write(key: _storageKey, value: key);
  }

  /// What key is currently stored? (for settings display)
  static Future<String?> getStoredKey() async {
    return await _secureStorage.read(key: _storageKey);
  }

  static McpTool get definition => McpTool(
        name: 'web_search',
        description: '搜索互联网获取最新信息，当需要实时数据、新闻、天气、价格等信息时使用',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': '搜索关键词',
            },
          },
          'required': ['query'],
        },
        category: '网络工具',
      );

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';
    if (query.isEmpty) return {'success': false, 'error': '搜索词不能为空'};

    final key = await _apiKey();

    try {
      final response = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $key',
        },
        body: jsonEncode({
          'query': query,
          'max_results': 5,
          'search_depth': 'basic',
        }),
      );

      if (response.statusCode != 200) {
        return {'success': false, 'error': '搜索失败: ${response.statusCode}'};
      }

      final data = jsonDecode(response.body);
      final results = (data['results'] as List?)?.take(5).map((r) => {
            'title': r['title'],
            'url': r['url'],
            'content': r['content'],
          }).toList() ?? [];

      return {
        'success': true,
        'query': query,
        'results': results,
        'answer': data['answer'] ?? '',
      };
    } catch (e) {
      return {'success': false, 'error': '网络错误: $e'};
    }
  }
}
