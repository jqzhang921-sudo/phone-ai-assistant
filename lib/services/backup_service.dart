import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 导入结果的计数，用来给用户一个"到底进来了多少"的交代。
class ImportSummary {
  int conversations = 0;
  int trashedConversations = 0;
  int bookConversations = 0;
  int diaryEntries = 0;
  int musings = 0;
  int letters = 0;
  int books = 0;
  int otherKeys = 0;

  int get total =>
      conversations +
      trashedConversations +
      bookConversations +
      diaryEntries +
      musings +
      letters +
      books;
}

/// 全 App 数据的导出 / 导入。
///
/// **只带内容，不带凭证。** 导出文件的用途是发微信、存网盘，密钥一旦打包
/// 进去就等于从这里漏出来。主 API Key 在 flutter_secure_storage、其余密钥
/// 在 SharedPreferences，一律不导——导入后需要重新填一次。
/// 端点、模型名、供应商列表这些非密钥配置照导，所以重填时只需要粘贴 key 本身。
class BackupService {
  static const formatVersion = 1;

  /// 白名单：只有列在这里的 SharedPreferences 键会被导出。
  /// 没列出来的一律排除，这样以后新增的键不会意外泄露。
  static const _allowedKeys = <String>[
    'diary_entries',
    'favorited_musings',
    'today_musing',
    'letters',
    'last_letter_attempt_at',
    // 书架的**书目**。只是 JSON（书名/作者/状态/日期/封面路径），39 本约 8KB。
    // 封面图片本身仍然不导——那是 book_covers/ 下的二进制文件，转 base64 会让
    // 备份膨胀好几倍，这个判断没变。这里补的是书目本身：之前每本书的讨论历史
    // （discussions_ 前缀）都在备份里，书却不在，恢复出来是一堆无主的讨论。
    'bookshelf_books',
    'bookshelf_ignored_weread_ids',
    'chat_background_preset',
    'api_providers',
    // 稳定事实（关于用户是谁）。这一条**最不能漏**：日记和收藏丢了还能从
    // 对话里重新长出来，这层是它对用户的全部认识，换手机丢了就是从零重认识。
    // 上面 bookshelf_books 那次就是漏在这个列表里，别再来一遍。
    'memory_facts',
    // 手记的事实，丢了长不回来——对话里推不出她哪天来的例假。
    // 和 memory_facts 同一类：换手机漏了就是永久没了。
    //
    // ⚠️ **开关（period_share_with_ai）故意不在这儿。** 备份文件是会被
    // 带来带去的，恢复之后默认关着、重新选一次，比默默继续交出去稳妥。
    'period_spans',
  ];

  /// 同上，按前缀匹配的那些。
  static const _allowedPrefixes = <String>[
    'discussions_', // 每本书的讨论历史
    'api_name_', // 供应商显示名
    'api_endpoint_', // 端点 URL
    'api_model_', // 模型名
  ];

  /// 按 id 去重合并的列表型键。
  static const _mergeableListKeys = <String>[
    'diary_entries',
    'favorited_musings',
    'letters',
    'bookshelf_books',
  ];

  static bool _isAllowed(String key) {
    if (_allowedKeys.contains(key)) return true;
    return _allowedPrefixes.any(key.startsWith);
  }

  // ---------------- 导出 ----------------

  /// 组装备份内容。封面图不导（二进制转 base64 会让文件膨胀数倍），
  /// 导入后重新下载即可。
  static Future<Map<String, dynamic>> buildBackup() async {
    final dir = await getApplicationDocumentsDirectory();
    final prefs = await SharedPreferences.getInstance();

    final prefsMap = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      if (!_isAllowed(key)) continue;
      final value = prefs.get(key);
      if (value is String) {
        prefsMap[key] = {'type': 'string', 'value': value};
      } else if (value is List<String>) {
        prefsMap[key] = {'type': 'stringList', 'value': value};
      } else if (value is bool) {
        prefsMap[key] = {'type': 'bool', 'value': value};
      } else if (value is int) {
        prefsMap[key] = {'type': 'int', 'value': value};
      }
    }

    return {
      'app': 'phone_ai_assistant',
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'containsSecrets': false,
      'conversations': await _readJsonDir('${dir.path}/conversations'),
      'conversationsTrash': await _readJsonDir(
        '${dir.path}/conversations_trash',
      ),
      'bookConversations': await _readJsonDir('${dir.path}/book_conversations'),
      'prefs': prefsMap,
    };
  }

  /// 目录里的 json 文件读成 {文件名（不含扩展名）: 内容}。
  static Future<Map<String, dynamic>> _readJsonDir(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return {};
    final out = <String, dynamic>{};
    for (final entity in await dir.list().toList()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final name = entity.uri.pathSegments.last.replaceAll('.json', '');
        out[name] = jsonDecode(await entity.readAsString());
      } catch (_) {
        // 单个文件坏了不影响整体导出
      }
    }
    return out;
  }

  /// 写成临时文件，返回路径，交给分享面板。
  static Future<File> exportToFile() async {
    final backup = await buildBackup();
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/日记备份-$stamp.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(backup),
    );
    return file;
  }

  // ---------------- 导入 ----------------

  /// [replace] 为 true 时同 id 的内容会被备份里的覆盖；
  /// 为 false（默认）时只补充缺失的，本机已有的保持不动。
  static Future<ImportSummary> importBackup(
    Map<String, dynamic> backup, {
    bool replace = false,
  }) async {
    if (backup['app'] != 'phone_ai_assistant') {
      throw const FormatException('这个文件不是本 App 的备份');
    }
    final version = backup['formatVersion'];
    if (version is! int || version > formatVersion) {
      throw FormatException('备份格式版本 $version 比当前 App 新，先升级 App 再导入');
    }

    final dir = await getApplicationDocumentsDirectory();
    final summary = ImportSummary();

    summary.conversations = await _writeJsonDir(
      '${dir.path}/conversations',
      backup['conversations'],
      replace,
    );
    summary.trashedConversations = await _writeJsonDir(
      '${dir.path}/conversations_trash',
      backup['conversationsTrash'],
      replace,
    );
    summary.bookConversations = await _writeJsonDir(
      '${dir.path}/book_conversations',
      backup['bookConversations'],
      replace,
    );

    await _restorePrefs(backup['prefs'], replace, summary);
    return summary;
  }

  static Future<int> _writeJsonDir(
    String path,
    dynamic data,
    bool replace,
  ) async {
    if (data is! Map) return 0;
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    var count = 0;
    for (final entry in data.entries) {
      final file = File('$path/${entry.key}.json');
      if (!replace && await file.exists()) continue;
      await file.writeAsString(jsonEncode(entry.value));
      count++;
    }
    return count;
  }

  static Future<void> _restorePrefs(
    dynamic data,
    bool replace,
    ImportSummary summary,
  ) async {
    if (data is! Map) return;
    final prefs = await SharedPreferences.getInstance();

    for (final entry in data.entries) {
      final key = entry.key as String;
      if (!_isAllowed(key)) continue; // 备份被改过也不会写进不该写的键
      final wrapped = entry.value;
      if (wrapped is! Map) continue;
      final type = wrapped['type'];
      final value = wrapped['value'];

      if (type == 'string' && value is String) {
        if (_mergeableListKeys.contains(key)) {
          final added = await _mergeListPref(prefs, key, value, replace);
          if (key == 'diary_entries') {
            summary.diaryEntries += added;
          } else if (key == 'letters') {
            summary.letters += added;
          } else if (key == 'bookshelf_books') {
            summary.books += added;
          } else {
            summary.musings += added;
          }
          continue;
        }
        if (!replace && prefs.containsKey(key)) continue;
        await prefs.setString(key, value);
        summary.otherKeys++;
      } else if (type == 'stringList' && value is List) {
        if (!replace && prefs.containsKey(key)) continue;
        await prefs.setStringList(key, value.cast<String>());
        summary.otherKeys++;
      } else if (type == 'bool' && value is bool) {
        if (!replace && prefs.containsKey(key)) continue;
        await prefs.setBool(key, value);
        summary.otherKeys++;
      } else if (type == 'int' && value is int) {
        if (!replace && prefs.containsKey(key)) continue;
        await prefs.setInt(key, value);
        summary.otherKeys++;
      }
    }
  }

  /// 日记和一隅存的是 JSON 数组字符串，按 id 合并而不是整个覆盖，
  /// 这样导入旧备份不会把这之后新写的内容抹掉。
  static Future<int> _mergeListPref(
    SharedPreferences prefs,
    String key,
    String incomingRaw,
    bool replace,
  ) async {
    List<dynamic> incoming;
    try {
      incoming = jsonDecode(incomingRaw) as List<dynamic>;
    } catch (_) {
      return 0;
    }

    if (replace) {
      await prefs.setString(key, incomingRaw);
      return incoming.length;
    }

    List<dynamic> existing = [];
    final currentRaw = prefs.getString(key);
    if (currentRaw != null) {
      try {
        existing = jsonDecode(currentRaw) as List<dynamic>;
      } catch (_) {
        existing = [];
      }
    }

    final seen =
        existing
            .whereType<Map<String, dynamic>>()
            .map((e) => e['id'])
            .whereType<String>()
            .toSet();

    var added = 0;
    for (final item in incoming) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id'];
      if (id is String && seen.contains(id)) continue;
      existing.add(item);
      if (id is String) seen.add(id);
      added++;
    }

    await prefs.setString(key, jsonEncode(existing));
    return added;
  }
}
