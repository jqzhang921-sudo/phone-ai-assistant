import 'package:uuid/uuid.dart';

import '../../models/mcp_tool.dart';
import '../../models/memory_fact.dart';
import '../storage_service.dart';

/// 「稳定事实」的写入口：记住 / 改写 / 忘掉。
///
/// 为什么是这三个动作，而不是「重要性打分 + 自然衰减」：
///
/// 衰减是**静默**的。一条事实悄悄沉下去，从用户的角度和 bug 分不开——
/// 「我明明告诉过它」和「它坏了」长得一模一样。而这三个动作都是显式的：
/// 写了什么、改了什么、删了什么，记忆页上一条条看得见，也改得回来。
///
/// 而且在这个量级上衰减本来也无事可做：每类上限 8 条，四类共 32 条，
/// 没有「候选远多于槽位」这回事，没什么可挑的。真正的约束是**别乱记**，
/// 而不是「记多了怎么挑」。
///
/// 全部事实都在上下文里（见 buildStableFacts），所以模型写之前是**看得见**
/// 已有条目的——重复、冲突、该改而不是该加，它自己能判断。这是「记忆文件」
/// 那套做法的核心：索引常驻，写入前先读。
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

  /// 按短 id 前缀找一条。返回 (fact, error)，两者必有其一。
  ///
  /// 撞多条时**什么都不做**，只列候选让它多给几位——宁可让它再问一次，
  /// 也不猜。这条分支和 dairy-mcp 的 delete_diary 是同一套。
  static Future<(MemoryFact?, String?)> _find(String? rawId) async {
    final id = rawId?.trim().replaceAll(RegExp(r'[\[\]]'), '');
    if (id == null || id.length < 4) {
      return (null, 'id 至少给 4 位（上下文里每条前面方括号里的那串）。');
    }
    final facts = await StorageService.listMemoryFacts();
    final hits =
        facts.where((f) => shortFactId(f.id).startsWith(id.toLowerCase())).toList();
    if (hits.isEmpty) {
      return (null, '没有编号以「$id」开头的记忆。对一下上下文里的编号，别自己编。');
    }
    if (hits.length > 1) {
      final list = hits
          .map((f) => '[${shortFactId(f.id)}] ${f.content}')
          .join('\n');
      return (null, '「$id」匹配到 ${hits.length} 条，没动任何一条。多给几位：\n$list');
    }
    return (hits.first, null);
  }

  // ---------------- remember ----------------

  static McpTool get rememberDefinition => McpTool(
    name: 'remember',
    description:
        '把一件**关于用户是谁**的事长期记下来。这类事会一直待在你的上下文里，'
        '不用翻就知道。\n'
        '记什么：名字怎么称呼、TA 在意什么、最近在经历什么、TA 希望你怎么对 TA。\n'
        '不要记什么：某天发生的具体事件、某句具体的话——那些写日记或收进一隅，'
        '需要时用 recall_records 翻，不占常驻位置。\n'
        '**写之前先看你上下文里已经有的那些**：说的是同一件事就用 update_memory 改，'
        '不要再加一条；已经有了就什么都别做。\n'
        '一条只记一件事。两件挤一条里，将来改一件就得重写整条。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'category': {
          'type': 'string',
          'enum': MemoryCategory.values.map((c) => c.name).toList(),
          'description': _categoryHelp,
        },
        'content': {
          'type': 'string',
          'description':
              '一句话，陈述事实本身。写具体的（「不喜欢被反问」），'
              '不要写性格判断（「是个理性的人」）——那是标签，你会去演它。',
        },
        'why': {
          'type': 'string',
          'description':
              '为什么记这条 / 从哪儿知道的。比如「TA 自己说的」「从几次对话里看出来的」。'
              '这句很重要：以后你要判断该不该改这条，靠的就是它；'
              '用户在记忆页看到一条不认识的，也靠它判断你是不是编的。',
        },
      },
      'required': ['category', 'content', 'why'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> remember(Map<String, dynamic> args) async {
    try {
      final category = _parseCategory(args['category'] as String?);
      if (category == null) {
        return {'success': false, 'error': 'category 必须是下面之一：\n$_categoryHelp'};
      }
      final content = (args['content'] as String?)?.trim();
      if (content == null || content.isEmpty) {
        return {'success': false, 'error': '缺少 content（要记住的那句话）。'};
      }
      final why = (args['why'] as String?)?.trim();
      if (why == null || why.isEmpty) {
        return {
          'success': false,
          'error': '缺少 why。必须写清楚为什么记这条、从哪儿知道的——没有它，这条以后没人能判断真假。',
        };
      }

      final existing = await StorageService.listMemoryFactsIn(category);

      // 一模一样的不重复加。语义相近的挡不住，但那些你在上下文里看得见，
      // 该用 update_memory 改。
      final dup =
          existing.where((f) => f.content.trim() == content).firstOrNull;
      if (dup != null) {
        return {
          'success': true,
          'already': true,
          'message': '这条已经记着了（[${shortFactId(dup.id)}]），没有重复添加。',
        };
      }

      // 满了就**拒绝**，不挤掉最旧的那条。
      // 静默挤掉 = 用户看不见的遗忘，和 bug 分不开。
      if (existing.length >= StorageService.kMaxFactsPerCategory) {
        final list = existing
            .map((f) => '[${shortFactId(f.id)}] ${f.content}')
            .join('\n');
        return {
          'success': false,
          'error':
              '「${category.label}」已经记满 ${StorageService.kMaxFactsPerCategory} 条了，'
              '没有添加。先看看下面这些有没有过时的或能合并的，'
              '用 update_memory 改写、或 forget 删掉一条再来：\n$list',
        };
      }

      final fact = MemoryFact(
        id: _uuid.v4(),
        category: category,
        content: content,
        why: why,
        source: MemorySource.ai,
      );
      await StorageService.addMemoryFact(fact);
      return {
        'success': true,
        'id': shortFactId(fact.id),
        'message': '记下了。用户在「栖息 → 记忆」里能看到，也能改或删。',
      };
    } catch (e) {
      return {'success': false, 'error': '记不下来：$e'};
    }
  }

  // ---------------- update_memory ----------------

  static McpTool get updateDefinition => McpTool(
    name: 'update_memory',
    description:
        '改写一条已经记住的事。事情变了、或者当初记得不准，改它，'
        '**不要再加一条新的**——两条互相矛盾的事实留在那儿，比记错更糟。\n'
        '「最近」那一类尤其要盯着：过期了不改，它就变成假话。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': '上下文里那条前面方括号里的编号。'},
        'content': {'type': 'string', 'description': '新的那句话。不改内容就别给。'},
        'why': {'type': 'string', 'description': '为什么改成这样。不给就沿用原来的。'},
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
      final (fact, error) = await _find(args['id'] as String?);
      if (fact == null) return {'success': false, 'error': error};

      if (fact.pinned) {
        return {
          'success': false,
          'error':
              '这条是用户钉住的，你改不了：「${fact.content}」。'
              '如果你觉得它已经不对了，在对话里跟用户说一声，让 TA 自己改。',
        };
      }

      final content = (args['content'] as String?)?.trim();
      final why = (args['why'] as String?)?.trim();
      final category = _parseCategory(args['category'] as String?);
      if ((content == null || content.isEmpty) &&
          (why == null || why.isEmpty) &&
          category == null) {
        return {'success': false, 'error': 'content / why / category 至少要给一个，否则没什么可改的。'};
      }

      final updated = fact.copyWith(
        content: content == null || content.isEmpty ? null : content,
        why: why == null || why.isEmpty ? null : why,
        category: category,
      );
      final ok = await StorageService.updateMemoryFact(updated);
      if (!ok) return {'success': false, 'error': '没找到那条，什么都没改。'};

      return {
        'success': true,
        'before': fact.content,
        'after': updated.content,
        'message': '改好了。',
      };
    } catch (e) {
      return {'success': false, 'error': '改不了：$e'};
    }
  }

  // ---------------- forget ----------------

  static McpTool get forgetDefinition => McpTool(
    name: 'forget',
    description:
        '删掉一条记住的事。用在它已经彻底不成立、改写也没意义的时候'
        '（比如记错了人、或者那件事结束了很久）。\n'
        '只是**变了**的话用 update_memory 改，别删了重记——改写留得住来龙去脉。\n'
        '用户明确说「别记这个了」时也用这个。',
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
      final (fact, error) = await _find(args['id'] as String?);
      if (fact == null) return {'success': false, 'error': error};

      if (fact.pinned) {
        return {
          'success': false,
          'error':
              '这条是用户钉住的，你删不了：「${fact.content}」。'
              '觉得该删就在对话里说一声，让 TA 自己决定。',
        };
      }

      await StorageService.removeMemoryFact(fact.id);
      // 把删掉的正文一并返回：没有回收站，正文留在对话里就还能原样写回去。
      // （同 dairy-mcp 的 delete_diary。）
      return {
        'success': true,
        'deleted': fact.content,
        'message': '删掉了：「${fact.content}」。删错了的话，用 remember 原样写回去就行。',
      };
    } catch (e) {
      return {'success': false, 'error': '删不了：$e'};
    }
  }
}
