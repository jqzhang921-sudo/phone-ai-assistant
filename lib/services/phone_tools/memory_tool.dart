import 'package:uuid/uuid.dart';

import '../../models/mcp_tool.dart';
import '../../models/memory_topic.dart';
import '../storage_service.dart';

/// 长期记忆的四个动作：记住 / 打开 / 改写 / 忘掉。
///
/// 为什么是这四个，而不是「重要性打分 + 自然衰减」：
///
/// 衰减是**静默**的。一条记忆悄悄沉下去，从用户的角度和 bug 分不开——
/// 「我明明告诉过它」和「它坏了」长得一模一样。这四个动作都是显式的：
/// 写了什么、改了什么、删了什么，记忆页上一条条看得见，也改得回来。
///
/// 为什么多一个 [openDefinition]：这一版把记忆拆成「一行摘要常驻 + 细节按需取」，
/// 那就必须有个「取」的动作。没有它，摘要就成了断头路——知道有这条，
/// 却拿不到里面写了什么。
class MemoryTools {
  static const _uuid = Uuid();

  static MemoryCategory? _parseCategory(String? raw) {
    if (raw == null) return null;
    final name = raw.trim();
    for (final c in MemoryCategory.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  static String get _categoryHelp => MemoryCategory.values
      .map((c) => '${c.name}（${c.label}）：${c.hint}')
      .join('\n');

  static List<String> _cleanDetails(dynamic raw) {
    if (raw is! List) return [];
    return raw
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 按短 id 前缀找一条。返回 (topic, error)，两者必有其一。
  ///
  /// 撞多条时**什么都不做**，只列候选让它多给几位——宁可让它再问一次，
  /// 也不猜。这条分支和 dairy-mcp 的 delete_diary 是同一套。
  static Future<(MemoryTopic?, String?)> _find(String? rawId) async {
    final id = rawId?.trim().replaceAll(RegExp(r'[\[\]]'), '');
    if (id == null || id.length < 4) {
      return (null, '编号至少给 4 位（上下文里每条前面方括号里的那串）。');
    }
    final topics = await StorageService.listMemoryTopics();
    final hits =
        topics
            .where((t) => shortTopicId(t.id).startsWith(id.toLowerCase()))
            .toList();
    if (hits.isEmpty) {
      return (null, '没有编号以「$id」开头的记忆。对一下上下文里的编号，别自己编。');
    }
    if (hits.length > 1) {
      final list = hits
          .map((t) => '[${shortTopicId(t.id)}] ${t.name}')
          .join('\n');
      return (null, '「$id」匹配到 ${hits.length} 条，没动任何一条。多给几位：\n$list');
    }
    return (hits.first, null);
  }

  static Map<String, dynamic> _view(MemoryTopic t) => {
    'id': shortTopicId(t.id),
    'category': t.category.label,
    'name': t.name,
    'summary': t.summary,
    'details': t.details,
    'source': t.source == MemorySource.user ? '用户说的' : '你自己记的',
    if (t.pinned) 'pinned': true,
  };

  // ---------------- remember ----------------

  static McpTool get rememberDefinition => McpTool(
    name: 'remember',
    description:
        '开一条新的长期记忆，记**关于用户是谁**的事。\n'
        '一条记忆是一个「话题」：一个名字、一行摘要、若干条细节。'
        '摘要会一直待在你的上下文里，细节要用 open_memory 才取得到。\n'
        '记什么：怎么称呼 TA、TA 在意什么、最近在经历什么、希望你怎么对 TA。\n'
        '不要记：某天发生的具体事件、某句具体的话——那些写日记或收进一隅，'
        '要用时 recall_records 翻，不该占常驻位置。\n'
        '**先看上下文里已有的那些**：能塞进某个已有话题就用 update_memory 加细节，'
        '不要另开一条。同一件事分散在两条里，你自己以后也对不上。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'category': {
          'type': 'string',
          'enum': MemoryCategory.values.map((c) => c.name).toList(),
          'description': _categoryHelp,
        },
        'name': {
          'type': 'string',
          'description': '话题名，短，像个标题：「怎么称呼」「读书口味」「说话方式」。',
        },
        'summary': {
          'type': 'string',
          'description':
              '一行，说清**这条讲什么**，不是内容本身。'
              '这句会一直待在你上下文里，也是你以后判断「要不要打开这条」的唯一依据——'
              '写砸了这条记忆等于不存在，因为你想不起来该打开它。',
        },
        'details': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              '具体内容，一条一件事。写具体的（「不喜欢被反问」），'
              '不要写性格判断（「是个理性的人」）——那是标签，你会去演它。'
              '尽量带上从哪儿知道的（「TA 自己说的」），以后你和用户都要靠它判断真假。',
        },
      },
      'required': ['category', 'name', 'summary', 'details'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> remember(
    Map<String, dynamic> args,
  ) async {
    try {
      final category = _parseCategory(args['category'] as String?);
      if (category == null) {
        return {'success': false, 'error': 'category 必须是下面之一：\n$_categoryHelp'};
      }
      final name = (args['name'] as String?)?.trim();
      final summary = (args['summary'] as String?)?.trim();
      if (name == null || name.isEmpty) {
        return {'success': false, 'error': '缺少 name（话题名，短标题）。'};
      }
      if (summary == null || summary.isEmpty) {
        return {
          'success': false,
          'error': '缺少 summary。这是唯一常驻上下文的一行，没有它这条记忆你以后找不到。',
        };
      }
      final details = _cleanDetails(args['details']);
      if (details.isEmpty) {
        return {'success': false, 'error': '缺少 details。只有摘要没有内容，打开也是空的。'};
      }

      final existing = await StorageService.listMemoryTopicsIn(category);

      // 同名的不另开一条。名字一样八成说的就是同一件事，该去加细节。
      final dup =
          existing.where((t) => t.name.trim() == name).firstOrNull;
      if (dup != null) {
        return {
          'success': false,
          'error':
              '「${category.label}」里已经有个叫「$name」的话题了（[${shortTopicId(dup.id)}]）。'
              '用 open_memory 看看里面写了什么，该补就用 update_memory 加细节，别另开一条。',
        };
      }

      // 满了就**拒绝**，不挤掉最旧的那条。
      // 静默挤掉 = 用户看不见的遗忘，和 bug 分不开。
      if (existing.length >= StorageService.kMaxTopicsPerCategory) {
        final list = existing
            .map((t) => '[${shortTopicId(t.id)}] ${t.name}：${t.summary}')
            .join('\n');
        return {
          'success': false,
          'error':
              '「${category.label}」已经有 ${StorageService.kMaxTopicsPerCategory} 个话题了，'
              '没有新建。先看看这件事能不能并进下面某一条（用 update_memory 加细节），'
              '或者有没有过时的可以 forget：\n$list',
        };
      }

      final capped = details.take(StorageService.kMaxDetailsPerTopic).toList();
      final topic = MemoryTopic(
        id: _uuid.v4(),
        category: category,
        name: name,
        summary: summary,
        details: capped,
        source: MemorySource.ai,
      );
      await StorageService.addMemoryTopic(topic);
      return {
        'success': true,
        'id': shortTopicId(topic.id),
        if (capped.length < details.length)
          'note':
              '细节超过 ${StorageService.kMaxDetailsPerTopic} 条上限，只存了前 ${capped.length} 条。',
        'message': '记下了。用户在「栖息 → 记忆」里能看到，也能改或删。',
      };
    } catch (e) {
      return {'success': false, 'error': '记不下来：$e'};
    }
  }

  // ---------------- open_memory ----------------

  static McpTool get openDefinition => McpTool(
    name: 'open_memory',
    description:
        '把一条长期记忆的细节取出来。\n'
        '你上下文里只有每条的名字和一行摘要，具体内容在这里面。'
        '**要说到具体内容就先打开**，不要照着摘要猜——摘要只说这条讲什么，'
        '不说讲了什么。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': '上下文里那条前面方括号里的编号。'},
      },
      'required': ['id'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> open(Map<String, dynamic> args) async {
    try {
      final (topic, error) = await _find(args['id'] as String?);
      if (topic == null) return {'success': false, 'error': error};
      return {'success': true, ..._view(topic)};
    } catch (e) {
      return {'success': false, 'error': '打不开：$e'};
    }
  }

  // ---------------- update_memory ----------------

  static McpTool get updateDefinition => McpTool(
    name: 'update_memory',
    description:
        '改一条已有的长期记忆：加一条细节、改摘要、或者整体重写细节。\n'
        '知道了新东西、而它属于某个已有话题，用这个加细节，'
        '**不要另开一条**——同一件事分散在两条里，你自己以后也对不上。\n'
        '事情变了、或者当初记错了，改它，别留着两条互相矛盾的。\n'
        '「最近」那一类尤其要盯着：过期了不改，它就变成假话。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': '上下文里那条前面方括号里的编号。'},
        'add_detail': {
          'type': 'string',
          'description': '追加一条细节。最常用的就是这个，安全，不动已有内容。',
        },
        'set_details': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              '**整体替换**所有细节，不是追加。要删掉或改写某条细节时才用。'
              '用之前先 open_memory 读出来，把要保留的一起写回去——'
              '不读就写等于把这条记忆清空重写。',
        },
        'summary': {'type': 'string', 'description': '新的一行摘要。不改就别给。'},
        'name': {'type': 'string', 'description': '新的话题名。不改就别给。'},
        'category': {
          'type': 'string',
          'enum': MemoryCategory.values.map((c) => c.name).toList(),
          'description': '要换分类才给。不换就别给。',
        },
      },
      'required': ['id'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> update(Map<String, dynamic> args) async {
    try {
      final (topic, error) = await _find(args['id'] as String?);
      if (topic == null) return {'success': false, 'error': error};

      if (topic.pinned) {
        return {
          'success': false,
          'error':
              '这条是用户钉住的，你改不了：「${topic.name}」。'
              '如果你觉得它已经不对了，在对话里跟用户说一声，让 TA 自己改。',
        };
      }

      final addDetail = (args['add_detail'] as String?)?.trim();
      final hasSetDetails = args['set_details'] is List;
      final setDetails = _cleanDetails(args['set_details']);
      final summary = (args['summary'] as String?)?.trim();
      final name = (args['name'] as String?)?.trim();
      final category = _parseCategory(args['category'] as String?);

      if ((addDetail == null || addDetail.isEmpty) &&
          !hasSetDetails &&
          (summary == null || summary.isEmpty) &&
          (name == null || name.isEmpty) &&
          category == null) {
        return {'success': false, 'error': '什么都没给，也就没什么可改的。'};
      }

      // 两个都给了，说不清到底想干嘛——拒绝，别猜。
      if (addDetail != null && addDetail.isNotEmpty && hasSetDetails) {
        return {
          'success': false,
          'error': 'add_detail 和 set_details 只能给一个：一个是追加，一个是整体替换，同时给说不清你想要哪个。',
        };
      }

      List<String>? details;
      if (hasSetDetails) {
        details = setDetails.take(StorageService.kMaxDetailsPerTopic).toList();
      } else if (addDetail != null && addDetail.isNotEmpty) {
        if (topic.details.contains(addDetail)) {
          return {
            'success': true,
            'already': true,
            'message': '这条细节已经在里面了，没有重复添加。',
          };
        }
        if (topic.details.length >= StorageService.kMaxDetailsPerTopic) {
          return {
            'success': false,
            'error':
                '「${topic.name}」的细节已经有 ${StorageService.kMaxDetailsPerTopic} 条了。'
                '先 open_memory 看看有没有过时的，用 set_details 把该留的写回去。',
          };
        }
        details = [...topic.details, addDetail];
      }

      final updated = topic.copyWith(
        name: name == null || name.isEmpty ? null : name,
        summary: summary == null || summary.isEmpty ? null : summary,
        details: details,
        category: category,
      );
      final ok = await StorageService.updateMemoryTopic(updated);
      if (!ok) return {'success': false, 'error': '没找到那条，什么都没改。'};

      return {'success': true, ..._view(updated), 'message': '改好了。'};
    } catch (e) {
      return {'success': false, 'error': '改不了：$e'};
    }
  }

  // ---------------- forget ----------------

  static McpTool get forgetDefinition => McpTool(
    name: 'forget',
    description:
        '删掉一整条长期记忆。用在这个话题彻底不成立、改写也没意义的时候。\n'
        '只是**变了**的话用 update_memory 改，别删了重记——改写留得住来龙去脉。\n'
        '只想去掉其中一条细节，也用 update_memory 的 set_details，不要整条删。\n'
        '用户明确说「别记这个了」时用这个。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': '上下文里那条前面方括号里的编号。'},
      },
      'required': ['id'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> forget(Map<String, dynamic> args) async {
    try {
      final (topic, error) = await _find(args['id'] as String?);
      if (topic == null) return {'success': false, 'error': error};

      if (topic.pinned) {
        return {
          'success': false,
          'error':
              '这条是用户钉住的，你删不了：「${topic.name}」。'
              '觉得该删就在对话里说一声，让 TA 自己决定。',
        };
      }

      await StorageService.removeMemoryTopic(topic.id);
      // 把删掉的内容一并返回：没有回收站，正文留在对话里就还能原样写回去。
      // （同 dairy-mcp 的 delete_diary。）
      return {
        'success': true,
        'deleted': _view(topic),
        'message': '删掉了「${topic.name}」。删错了的话，用 remember 照着上面的内容写回去就行。',
      };
    } catch (e) {
      return {'success': false, 'error': '删不了：$e'};
    }
  }
}
