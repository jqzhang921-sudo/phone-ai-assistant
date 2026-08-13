import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../../models/mcp_tool.dart';

class SearchTool {
  static const _storageKey = 'tavily_api_key';
  static const _endpoint = 'https://api.tavily.com/search';

  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 用户在设置里填的 Tavily key；没填返回 null。
  ///
  /// 这里**不要**放任何默认 key：源码是公开仓库，写死的 key 等于公开发布，
  /// 而且会被编进每个 APK。没 key 时调用方直接走 Bing 兜底。
  static Future<String?> _apiKey() async {
    final stored = await _secureStorage.read(key: _storageKey);
    if (stored == null || stored.isEmpty) return null;
    return stored;
  }

  /// Save a new key (called from settings UI).
  static Future<void> saveKey(String key) async {
    await _secureStorage.write(key: _storageKey, value: key);
  }

  /// What key is currently stored? (for settings display)
  static Future<String?> getStoredKey() async {
    return await _secureStorage.read(key: _storageKey);
  }

  /// 描述里反复强调 query 必填，是为了压低空调用率。
  ///
  /// DeepSeek 偶尔会先发一个 `arguments: {}` 的调用，吃到「搜索词不能为空」
  /// 再自己重试成功——白白多一轮往返。光把 query 放进 `required` 数组不够，
  /// 模型更吃描述里的自然语言约束，所以描述、参数说明、minLength 三处都写死。
  static McpTool get definition => McpTool(
        name: 'web_search',
        description: '搜索互联网获取最新信息，当需要实时数据、新闻、价格等信息时使用。'
            '**查天气请用 get_weather，不要用这个**——搜索引擎抓回来的是城市百科，'
            '没有天气数据。'
            '调用时必须带上非空的 query 参数，例如 {"query": "iPhone 17 售价"}。'
            '禁止发出 {} 或 query 为空字符串的调用——那样只会拿到报错。'
            '如果还没想清楚要搜什么，就先别调用这个工具，或者先把用户的问题原样填进 query。',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': '搜索关键词，必填，不能为空字符串。'
                  '写成具体的自然语言短句，例如「iPhone 17 售价」「上海地铁 14 号线 首末班车」。',
              'minLength': 1,
            },
          },
          'required': ['query'],
        },
        category: '网络工具',
      );

  /// 两个都试：不同网络落到的 Bing 不一样。
  ///
  /// 实测国内直连时 www 通、cn 连不上；换个运营商/地区可能正好相反。一个不行
  /// 就换另一个，比赌哪个能通靠谱。
  static const _bingHosts = ['www.bing.com', 'cn.bing.com'];

  /// Bing 兜底搜索（无需 key）：抓搜索结果页解析标题/链接/摘要。
  ///
  /// ⚠️ 这条路查不了天气。Bing 的天气答案卡靠 JS 渲染或只发给完整浏览器会话，
  /// 抓回来的静态页里一个 `b_ans`/`wtr_` 都没有，`b_algo` 里只有城市百科词条。
  /// 天气走 WeatherTool。
  static Future<Map<String, dynamic>> _searchBing(String query) async {
    final failures = <String>[];

    for (final host in _bingHosts) {
      try {
        final url = Uri.parse(
            'https://$host/search?q=${Uri.encodeQueryComponent(query)}&setlang=zh-CN');
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
          failures.add('$host 返回 ${resp.statusCode}');
          continue;
        }

        final html = resp.body;
        final results = _parseBing(html);
        if (results.isNotEmpty) {
          return {
            'success': true,
            'query': query,
            'results': results,
            'source': 'bing($host)',
          };
        }
        // 拿到页面却解析不出来：把线索带上，否则下次还是只能猜。
        failures.add(_diagnose(host, html));
      } catch (e) {
        failures.add('$host 网络错误: $e');
      }
    }

    return {'success': false, 'error': 'Bing 兜底失败——${failures.join('；')}'};
  }

  /// 页面拿到了但一条都没解析出来时，说清楚到底拿到了什么。
  ///
  /// 原来一律回「页面结构可能变化」，分不清是没结果、是同意页、还是人机验证，
  /// 拿着这条报错谁也断不了案。
  static String _diagnose(String host, String html) {
    final size = html.length;
    if (html.contains('b_algo')) {
      return '$host 页面里有 b_algo 但没解析出结果（结构变了，$size 字符）';
    }
    final lowered = html.toLowerCase();
    if (lowered.contains('captcha') ||
        lowered.contains('verify') ||
        html.contains('人机验证')) {
      return '$host 返回了人机验证页（$size 字符）';
    }
    if (lowered.contains('consent') || lowered.contains('cookie')) {
      return '$host 返回了同意/Cookie 页（$size 字符）';
    }
    if (size < 5000) {
      return '$host 返回的页面异常短（$size 字符），可能被拦截或重定向了';
    }
    return '$host 页面里连 b_algo 都没有（$size 字符）';
  }

  /// 结果块 → 标题/链接/摘要。
  ///
  /// 比原来宽：class 只要**含** b_algo 就算（原来要求恰好是 "b_algo"，多一个
  /// class 就整块漏掉）；标题桌面版是 `<a href><h2>`、移动版是 `<h2><a href>`，
  /// 两种都试；摘要按 b_lineclamp → b_caption → 任意 <p> 逐级退。
  static List<Map<String, dynamic>> _parseBing(String html) {
    final results = <Map<String, dynamic>>[];
    for (final m in _blockRe.allMatches(html)) {
      if (results.length >= 5) break;
      final block = m.group(0)!;

      String? url;
      String? title;
      for (final re in _titlePatterns) {
        final hit = re.firstMatch(block);
        if (hit == null) continue;
        final u = hit.group(1) ?? '';
        final t = _stripTags(hit.group(2) ?? '');
        if (u.isEmpty || t.isEmpty) continue;
        // Bing 自家的导航/跳转链接不算结果
        if (u.contains('bing.com') || u.contains('microsoft.com')) continue;
        url = u;
        title = t;
        break;
      }
      if (url == null || title == null) continue;

      var snippet = '';
      for (final re in _snippetPatterns) {
        final hit = re.firstMatch(block);
        if (hit == null) continue;
        snippet = _stripTags(hit.group(1) ?? '');
        if (snippet.isNotEmpty) break;
      }

      results.add({'title': title, 'url': url, 'content': snippet});
    }
    return results;
  }

  static final _blockRe = RegExp(
    r'<li[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>[\s\S]*?</li>',
    caseSensitive: false,
  );

  static final _titlePatterns = [
    // 桌面版：<a href="..."> … <h2>标题</h2>
    RegExp(
      r'<a[^>]*href="(https?://[^"]+)"[^>]*>[\s\S]{0,400}?<h2[^>]*>([\s\S]*?)</h2>',
      caseSensitive: false,
    ),
    // 移动版：<h2><a href="...">标题</a></h2>
    RegExp(
      r'<h2[^>]*>\s*<a[^>]*href="(https?://[^"]+)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    ),
  ];

  static final _snippetPatterns = [
    RegExp(r'<p class="[^"]*b_lineclamp[^"]*"[^>]*>([\s\S]*?)</p>',
        caseSensitive: false),
    RegExp(
        r'<div class="[^"]*b_caption[^"]*"[^>]*>[\s\S]*?<p[^>]*>([\s\S]*?)</p>',
        caseSensitive: false),
    RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false),
  ];

  static String _stripTags(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static Future<Map<String, dynamic>> execute(
      Map<String, dynamic> args) async {
    // 不要 `as String?`：模型偶尔会把 query 塞成数字或数组，硬转会抛类型异常。
    // 顺手 trim，纯空格的 query 等同于没填。
    final query = (args['query']?.toString() ?? '').trim();
    if (query.isEmpty) {
      // 报错文案写成「怎么修」而不是「哪里错」：模型收到后能一次重试对，
      // 少绕一轮。
      return {
        'success': false,
        'error': 'query 参数为空。请重新调用 web_search，'
            '并在 arguments 里给出非空的 query，例如 {"query": "iPhone 17 售价"}。',
      };
    }

    final key = await _apiKey();

    // 没配 Tavily key 就直接用 Bing——搜索照常可用，只是少了 Tavily 的摘要
    if (key == null) return await _searchBing(query);

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
        // 每条结果截断到 600 字：Tavily 返回的是整页抓取原文，里面混着
        // 「扫一扫 分享到微信」「返回顶部」「京ICP备…」这类导航垃圾。
        // 原样送回去，模型收到的是几万字符的噪音，真正的信息反而被埋掉。
        final results =
            (data['results'] as List?)?.take(5).map((r) {
              final content = (r['content'] ?? '').toString().trim();
              return {
                'title': r['title'],
                'url': r['url'],
                'content':
                    content.length > 600
                        ? '${content.substring(0, 600)}…'
                        : content,
              };
            }).toList() ??
            [];
        if (results.isNotEmpty) {
          final answer = (data['answer'] ?? '').toString().trim();
          return {
            'success': true,
            'query': query,
            'results': results,
            // 空字段不要送出去：模型看到 `answer:` 是空的，容易判断成「没结果」
            if (answer.isNotEmpty) 'answer': answer,
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
