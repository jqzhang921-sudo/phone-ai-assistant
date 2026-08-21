import 'package:uuid/uuid.dart';

import '../../config/settings.dart';
import '../../models/mcp_tool.dart';
import '../../models/musing_entry.dart';
import '../storage_service.dart';

/// 翻自己的记录：一隅里的收藏、写过的日记。
///
/// 为什么是工具而不是把内容都塞进上下文：
///
/// 聊天上下文里只带最近 5 条收藏、3 篇日记——那是「大致记得」的量，
/// 每条消息都要付一次 token。要让它答得全，就得把全部记录常驻上下文，
/// 条目越攒越多，每句闲聊都在为一次可能不会发生的追问买单。
///
/// 做成工具之后，上下文那几条继续管「隐约记得有这么回事」，
/// 真被追问了就去翻。**记不清、但翻得到**——这本来就是人的方式。
///
/// 一个工具管两种记录，而不是拆成两个：用户问「你记不记得我说过 X」时，
/// 它自己也不知道 X 是在收藏里还是日记里，一次搜两边才是有用的默认行为。
class RecallTool {
  static const _defaultLimit = 10;
  static const _maxLimit = 30;

  static McpTool get definition => McpTool(
    name: 'recall_records',
    description:
        '翻你自己那边的记录：一隅里收藏的话、你写过的日记。'
        '聊天上下文里只带了最近几条，用户问起更早的、或者问「一共收了哪些」、'
        '「你还记不记得我说过⋯」这类需要翻查的问题时，用这个查，不要凭印象编。'
        '给了 keyword 就按关键词搜，不给就按时间倒序列最近的。'
        '查不到就如实说没有。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['all', 'favorites', 'diaries'],
          'description': '查哪一类。不确定在哪就用 all（默认），一次搜两边。',
        },
        'keyword': {
          'type': 'string',
          'description': '关键词，按内容里是否包含来筛。留空就是列最近的。',
        },
        'limit': {
          'type': 'integer',
          'description': '最多返回多少条，默认 $_defaultLimit，上限 $_maxLimit。',
        },
      },
    },
    category: '手机工具',
  );

  static String _saidBy(MusingEntry m) => switch (m.source) {
    MusingSource.musing => '你在「我想说」写的',
    MusingSource.ai => '你在聊天里说的',
    MusingSource.user => '用户说的',
  };

  static String _savedBy(MusingEntry m) => switch (m.savedBy) {
    MusingSavedBy.user => '用户收的',
    MusingSavedBy.ai => '你自己收的',
    MusingSavedBy.both => '你们各自都收了',
  };

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final kind = (args['kind'] as String?)?.trim() ?? 'all';
      final keyword = (args['keyword'] as String?)?.trim();
      final rawLimit = args['limit'];
      final limit = switch (rawLimit) {
        int n => n.clamp(1, _maxLimit),
        String s => (int.tryParse(s) ?? _defaultLimit).clamp(1, _maxLimit),
        _ => _defaultLimit,
      };

      bool hit(String content) =>
          keyword == null ||
          keyword.isEmpty ||
          content.toLowerCase().contains(keyword.toLowerCase());

      final items = <Map<String, dynamic>>[];

      if (kind == 'all' || kind == 'favorites') {
        final musings = await StorageService.listFavoritedMusings();
        for (final m in musings.where((m) => hit(m.content))) {
          items.add({
            'type': '收藏',
            'date': m.dateKey,
            'said_by': _saidBy(m),
            'saved_by': _savedBy(m),
            'content': m.content,
            if (m.note != null && m.note!.isNotEmpty) 'note': m.note,
          });
        }
      }

      if (kind == 'all' || kind == 'diaries') {
        final diaries = await StorageService.listDiaryEntries();
        for (final d in diaries.where((d) => hit(d.content))) {
          items.add({'type': '日记', 'date': d.dateKey, 'content': d.content});
        }
      }

      // 两类混在一起时按日期倒序，读起来才是一条时间线
      items.sort(
        (a, b) => (b['date'] as String).compareTo(a['date'] as String),
      );
      final total = items.length;
      final shown = items.take(limit).toList();

      return {
        'success': true,
        'total': total,
        'returned': shown.length,
        'items': shown,
        if (total > shown.length)
          'note': '还有 ${total - shown.length} 条没列出来，需要的话缩小关键词或调大 limit。',
        if (total == 0)
          'note':
              keyword == null || keyword.isEmpty
                  ? '这一类还没有记录。'
                  : '没有包含「$keyword」的记录——如实说没找到，不要编。',
      };
    } catch (e) {
      return {'success': false, 'error': '翻记录失败：$e'};
    }
  }
}

/// 把一句话收进一隅。
///
/// 补的是一个说得出、做不到的缺口：之前只给了它「翻」（[RecallTool]），
/// 没给「收」。于是用户说「你收藏一下这句」，它嘴上答应，实际存不进去，
/// 下次去翻自然什么也没有——比不答应更糟。
///
/// 自主收藏那条路（`favorite_picker`）是它回看时自己挑，受设置开关和
/// 12 小时冷却约束；这个工具是**对话当场**的动作，用户看得见、
/// 在一隅里随时能取消，所以不另设开关。
class SaveToCornerTool {
  static const _uuid = Uuid();

  static McpTool get definition => McpTool(
    name: 'save_to_corner',
    description:
        '把一句话收进「一隅」。'
        '用在两种时候：用户明确让你收下某句话；或者对话里出现了一句你真觉得'
        '值得留下的话（过几个月再读还有分量的那种，不是随口的应答）。'
        '**答应了就要真的调用这个工具**——只在嘴上说「我收下了」而不调用，'
        '用户下次去翻会发现什么都没有。'
        '同一句不要重复收；收完简单说一句就行，不用复述全文。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'content': {'type': 'string', 'description': '要收藏的原话，照原样写，不要改写或概括。'},
        'said_by': {
          'type': 'string',
          'enum': ['user', 'me'],
          'description': '这句话是谁说的：user = 用户说的，me = 你说的。',
        },
        'asked_by_user': {
          'type': 'boolean',
          'description':
              '是不是用户让你收的。用户开口要你收就填 true；'
              '你自己觉得值得留、用户没提，填 false。如实填——'
              '用户可能关掉了「让沐自己收藏」，那时 false 会被拒绝。',
        },
      },
      'required': ['content', 'said_by', 'asked_by_user'],
    },
    category: '手机工具',
  );

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    try {
      final content = (args['content'] as String?)?.trim();
      if (content == null || content.isEmpty) {
        return {'success': false, 'error': '缺少 content 参数（要收藏的原话）'};
      }
      final saidByArg = (args['said_by'] as String?)?.trim();
      if (saidByArg != 'user' && saidByArg != 'me') {
        return {'success': false, 'error': 'said_by 只能是 user 或 me'};
      }

      // 用户没开「让沐自己收藏」时，它不该借这个工具绕过去自作主张。
      // 用户开口要的不受限制——那是 TA 的意思，不是它的。
      final askedByUser = args['asked_by_user'] == true;
      if (!askedByUser) {
        final settings = await AppSettings.load();
        if (!settings.aiSelfFavorite) {
          return {
            'success': false,
            'error':
                '用户没有开「让沐自己收藏」，你不能自己决定收。'
                '想收的话可以问一句 TA 要不要收，TA 同意了再调一次'
                '（asked_by_user 填 true）。',
          };
        }
      }

      final existing = await StorageService.listFavoritedMusings();
      final dup =
          existing.where((e) => e.content.trim() == content).firstOrNull;
      if (dup != null) {
        // 用户收过的，它再收就是「各自都收了」——那是有意义的重合，不是重复条目
        if (dup.savedBy == MusingSavedBy.user) {
          await StorageService.removeFavoritedMusing(dup.id);
          await StorageService.addFavoritedMusing(dup.sharedWith);
          return {
            'success': true,
            'already': true,
            'message': '这句用户已经收过了，现在标成「你们各自都收了」。',
          };
        }
        return {
          'success': true,
          'already': true,
          'message': '这句一隅里已经有了，没有重复添加。',
        };
      }

      final entry = MusingEntry(
        id: _uuid.v4(),
        date: DateTime.now(),
        content: content,
        source: saidByArg == 'user' ? MusingSource.user : MusingSource.ai,
        savedBy: MusingSavedBy.ai,
      );
      await StorageService.addFavoritedMusing(entry);

      return {'success': true, 'message': '已经收进「一隅」了，用户在「栖息 → 一隅」能看到，也能随时取消。'};
    } catch (e) {
      return {'success': false, 'error': '收藏失败：$e'};
    }
  }
}
