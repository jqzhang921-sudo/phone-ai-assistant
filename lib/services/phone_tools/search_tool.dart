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

  /// Bing 兜底搜索（无需 key，国内可直连）：抓取搜索结果页解析标题/链接/摘要。
  static Future<Map<String, dynamic>> _searchBing(String query) async {
    final url = Uri.parse(
        'https://www.bing.com/search?q=${Uri.encodeQueryComponent(query)}&setlang=zh-CN');
    try {
      final resp = await http.get(
        url,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      );
      if (resp.statusCode != 200) {
        return {'success': false, 'error': 'Bing 搜索失败: ${resp.statusCode}'};
      }
      final html = resp.body;

      // 解析 b_algo 结果块：<div class="b_algoheader"><a href="URL"><h2>标题</h2></a></div> + <p>摘要</p>
      final algoRe = RegExp(
        r'<li class="b_algo"[\s\S]*?</li>',
        caseSensitive: false,
      );
      final results = <Map<String, dynamic>>[];
      for (final m in algoRe.allMatches(html).take(5)) {
        final block = m.group(0)!;
        // 新结构：b_algoheader 里 <a href="URL"><h2>标题</h2></a>
        final titleMatch = RegExp(
          r'<div class="b_algoheader"><a[^>]*href="([^"]+)"[^>]*>[\s\S]*?<h2[^>]*>([\s\S]*?)</h2>[\s\S]*?</a>',
          caseSensitive: false,
        ).firstMatch(block);
        if (titleMatch == null) continue;
        final rawTitle = titleMatch
            .group(2)!
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
        if (rawTitle.isEmpty) continue;
        final urlMatch = titleMatch.group(1) ?? '';
        // 过滤 Bing 自家导航/空链接
        if (urlMatch.isEmpty || urlMatch.startsWith('javascript:')) continue;
        final snippetMatch = RegExp(
          r'<p class="b_lineclamp[^"]*">([\s\S]*?)</p>',
          caseSensitive: false,
        ).firstMatch(block);
        final snippet = (snippetMatch?.group(1) ?? '')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
        results.add({
          'title': rawTitle,
          'url': urlMatch,
          'content': snippet,
        });
      }

      if (results.isEmpty) {
        return {'success': false, 'error': 'Bing 没有解析到结果（页面结构可能变化）'};
      }
      return {
        'success': true,
        'query': query,
        'results': results,
        'answer': '',
        'source': 'bing',
      };
    } catch (e) {
      return {'success': false, 'error': 'Bing 网络错误: $e'};
    }
  }

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    final query = args['query'] as String? ?? '';
    if (query.isEmpty) return {'success': false, 'error': '搜索词不能为空'};

    final key = await _apiKey();

    // 1) 先走 Tavily
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = (data['results'] as List?)?.take(5).map((r) => {
              'title': r['title'],
              'url': r['url'],
              'content': r['content'],
            }).toList() ?? [];
        if (results.isNotEmpty) {
          return {
            'success': true,
            'query': query,
            'results': results,
            'answer': data['answer'] ?? '',
            'source': 'tavily',
          };
        }
      }
      // Tavily 失败/无结果 → 降级 Bing
      final bing = await _searchBing(query);
      if (bing['success'] == true) return bing;
      // Bing 也失败 → 报 Tavily 的原始错误（更可能定位问题）
      if (response.statusCode != 200) {
        return {'success': false, 'error': 'Tavily 失败(${response.statusCode})，Bing 兜底也失败: ${bing['error']}'};
      }
      return {'success': false, 'error': 'Tavily 无结果，Bing 兜底也失败: ${bing['error']}'};
    } catch (e) {
      // 2) Tavily 网络异常 → 直接降级 Bing
      final bing = await _searchBing(query);
      if (bing['success'] == true) return bing;
      return {'success': false, 'error': '搜索网络错误: $e；Bing 兜底也失败: ${bing['error']}'};
    }
  }
}
