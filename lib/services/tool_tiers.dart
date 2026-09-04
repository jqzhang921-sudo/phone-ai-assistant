import '../models/mcp_tool.dart';

/// 工具分两层：常驻的几个，和「用的时候再取」的其余全部。
///
/// ## 为什么要分
///
/// 实测过一次：28 个工具的描述加 schema，每轮驮着约 13,000 token。但**花钱
/// 不是主要问题**——那部分进 KV 缓存，第二轮起基本不重复付。真正的问题是
/// 注意力：28 个里挑一个，和 8 个里挑一个，模型的表现不一样。
///
/// 这件事在这个项目里被证实过——`remember` 当初注册着、描述写得很清楚，
/// 它就是不用，最后靠往 system 前缀塞一段规矩才动起来。那是给症状打补丁。
///
/// ## ⚠️ 和 prompt 缓存的账
///
/// `tools` 数组在缓存前缀里（和 `messages` 平级进请求）。**它一变，后面
/// 整段对话历史就得按未命中价重算**——这正是 `ai_client._attachMemory`
/// 把记忆挂到消息尾部、而不是塞进 system 块的原因。
///
/// 所以这里的规矩是 [_loaded] **只增不减，换对话才清**：
/// 取一次工具赔一次缓存，取完前缀重新稳定下来，不是每轮都赔。
///
/// 算过账：常驻少 8,000 token（缓存价约 1/10）→ 每轮省 800，一天一百轮省
/// 8 万；一次落空多花约 5,400，一天搜几次花一万五。划算，而且注意力那笔
/// 根本没计价。
///
/// ## 为什么不挂在消息尾部（记忆那套做法）
///
/// 因为**不在 `tools` 数组里的工具，模型根本调不了**——function calling
/// 只认声明过的。挂尾部它只能看见定义，不能用。
///
/// ## ⚠️ 这个做法有一个固有的失败方式
///
/// 它可能**意识不到自己该去搜**。索引只给名字和一句话，名字要是不显眼，
/// 它就直接用别的办法凑合，或者告诉用户做不了——而且这个失败是静默的。
///
/// 所以 [ToolFinder] 搜不到时**把整份索引原样列回去**，让它自己挑；
/// 而不是回一句「没找到」把路堵死。
class ToolTiers {
  /// 常驻的：聊天中途真会用到的那几个。
  ///
  /// 判据是「她随口说一句，它当场就得能接」——而不是「她专门让它做一件事」。
  /// 相机、传感器、文件、闹钟、日历这些属于后者，进延迟层。
  ///
  /// `get_time` 不在这儿是因为它被删了：每条消息都带 `[time: ...]`
  /// （见 `ai_client._withTimestamp`），那个工具是纯冗余。
  static const resident = <String>{
    'memory',
    'follow_up_later',
    'add_small_thing',
    'save_to_corner',
    'write_diary_entry',
    'recall_records',
    // 找工具这件事本身必须常驻，否则延迟层等于不存在
    'find_tools',
  };

  /// 这段对话里已经取出来的延迟工具。**只增不减**，理由见类注释。
  static final Set<String> _loaded = <String>{};
  static String? _conversationId;

  /// 全部工具的快照，给 [ToolFinder] 搜。
  ///
  /// 用静态字段传，是因为工具执行器的签名只有 `args`，拿不到调用现场——
  /// 和 `SelfNoteTool.currentConversationId` 同一个理由。
  static List<McpTool> _all = const [];

  /// 每次发消息前调一次。换了对话就把取出来的清空——新对话本来就是新缓存。
  static void begin(String conversationId, List<McpTool> allTools) {
    _all = allTools;
    if (_conversationId != conversationId) {
      _conversationId = conversationId;
      _loaded.clear();
    }
  }

  static bool isResident(McpTool t) => resident.contains(t.name);

  /// 这一轮真正声明给模型的：常驻 + 这段对话里已经取出来的。
  static List<McpTool> active(List<McpTool> allTools) =>
      allTools.where((t) => isResident(t) || _loaded.contains(t.name)).toList();

  /// 收着的那些。**索引里始终列全部延迟工具**，取出来的也留在里面——
  /// 否则取一次工具，索引和 tools 数组会一起变，缓存白赔两次。
  static List<McpTool> deferred(List<McpTool> allTools) =>
      allTools.where((t) => !isResident(t)).toList();

  static void markLoaded(String name) => _loaded.add(name);

  /// 给测试用：把状态清干净。
  static void resetForTest() {
    _loaded.clear();
    _conversationId = null;
    _all = const [];
  }

  static List<McpTool> get allForSearch => _all;

  /// 一行索引，进 system 前缀。
  ///
  /// 一个工具约 20 token，比完整定义（平均 500+）便宜一个数量级。
  /// 这段是静态的——只有连上/断开外部服务器才变，所以吃得住缓存。
  static String buildIndex(List<McpTool> allTools) {
    final list = deferred(allTools);
    if (list.isEmpty) return '';
    final lines = list.map((t) => '- ${t.name}：${oneLine(t)}').join('\n');
    return '## 还能取用的工具\n'
        '下面这些**手上没有**，只有名字和一句话。要用哪个，'
        '先 find_tools 把完整用法取出来，取出来这轮就能直接调。\n'
        '$lines';
  }

  /// 把一段长描述压成一句。
  ///
  /// 取第一个句号/换行之前的部分——这些描述都是「这个工具干什么」开头，
  /// 后面才是「什么时候用、什么时候别用」，那些留给取出来之后再看。
  static String oneLine(McpTool t, {int max = 28}) {
    var s = t.description.trim();
    for (final sep in ['\n', '。', '（']) {
      final i = s.indexOf(sep);
      if (i > 0) s = s.substring(0, i);
    }
    s = s.replaceAll(RegExp(r'\*\*'), '').trim();
    return s.length <= max ? s : '${s.substring(0, max)}…';
  }
}

/// 「我要找个工具」——延迟层唯一的入口。
class ToolFinder {
  static McpTool get definition => McpTool(
    name: 'find_tools',
    description:
        '取一个手上没有的工具。\n'
        '你常驻的工具只有几个，其余的收在上下文里那份「还能取用的工具」清单里，'
        '只有名字和一句话。想做的事需要清单上某个工具，用这个把完整用法取出来——'
        '**取出来这一轮就能直接调**。\n'
        '说你想干什么就行，不用猜工具名。搜不到会把整份清单列回来给你自己挑。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': '你想干的事，用自己的话说。比如「拍张照」「查明天天气」「设个闹钟」。',
        },
      },
      'required': ['query'],
    },
    category: '手机工具',
  );

  /// 太常见、单独出现没有信息量的字。
  ///
  /// 只用来滤**单字**那一路。不滤的话「帮我订一张去冰岛的机票」会靠
  /// 「一」「张」「机」蹭上拍照那个工具（描述里有「拍一张照片」「手机」）——
  /// 而返回一个明显无关的工具，比老实说没找到更糟。
  static const _stop = {
    '的', '了', '是', '我', '你', '他', '她', '它', '们', '在', '有', '和',
    '就', '不', '人', '都', '会', '要', '到', '说', '这', '那', '上', '下',
    '来', '好', '想', '帮', '把', '给', '用', '能', '可', '以', '个', '一',
    '么', '什', '怎', '样', '为', '被', '让', '过', '还', '再', '也',
  };

  /// 二元组：和 `nudge_gate.looksRepeated` 同一招——换个词、调个语序，
  /// 编辑距离差很多，但共享的字对几乎一样。
  static Set<String> _bigrams(String s) {
    final t = s.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (t.length < 2) return {t};
    return {for (var i = 0; i < t.length - 1; i++) t.substring(i, i + 2)};
  }

  static Set<String> _chars(String s) => {
    for (final c in s.toLowerCase().replaceAll(RegExp(r'\s+'), '').split(''))
      if (!_stop.contains(c)) c,
  };

  /// ⚠️ **光靠二元组不行**，这是被测试抓出来的：
  ///
  /// 查询「拍照」的字对是 `{拍照}`，而描述里写的是「拍**一张**照片」——
  /// 拍和照不相邻，**重合为零**。而「我想拍张照」却能搜到，因为碰巧共享了
  /// 「张照」。也就是说：能不能搜到，取决于它把话说成什么样，这不成立。
  ///
  /// 所以二元组管精度、单字管召回，单字那路权重减半并且滤掉常用字。
  static double _score(String query, McpTool t) {
    final qb = _bigrams(query);
    if (qb.isEmpty) return 0;

    // 工具名多半是英文，中文查询和它对不上，所以名字单独算一次包含关系
    final name = t.name.toLowerCase();
    var s = 0.0;
    if (query.toLowerCase().contains(name) ||
        query.toLowerCase().contains(name.replaceAll('_', ' '))) {
      s += 2.0;
    }

    final blob = '${t.name} ${t.description}';
    s += qb.where(_bigrams(blob).contains).length / qb.length;

    final qc = _chars(query);
    if (qc.isNotEmpty) {
      final tc = _chars(blob);
      s += 0.5 * qc.where(tc.contains).length / qc.length;
    }
    return s;
  }

  static Future<Map<String, dynamic>> execute(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim() ?? '';
    if (query.isEmpty) {
      return {'success': false, 'error': '说一句你想干什么就行。'};
    }

    final pool = ToolTiers.deferred(ToolTiers.allForSearch);
    if (pool.isEmpty) {
      return {'success': false, 'error': '没有收着的工具，手上这几个就是全部。'};
    }

    final scored = pool.map((t) => (t, _score(query, t))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));

    // 加了单字那一路之后分数整体抬高，门槛跟着抬到 0.3。
    // 校准用的两个例子：「拍照」→ 0.5（要能搜到），
    // 「帮我订一张去冰岛的机票」→ 0.2（不能蹭上拍照）。
    // 宁可漏，不可错：搜不到还会把整份清单摊开让它自己挑，
    // 而返回一个无关的工具会让它真的去调。
    final hits = scored.where((e) => e.$2 >= 0.3).take(3).toList();

    if (hits.isEmpty) {
      // ⚠️ **不回一句「没找到」把路堵死。** 这个做法固有的失败方式就是
      // 「它意识不到该搜什么」，这会儿把整份清单摊开，它还能自己挑。
      return {
        'success': false,
        'error': '按「$query」没找到对得上的。下面是全部收着的工具，自己挑一个再搜一次：',
        'available': [
          for (final t in pool) '${t.name}：${ToolTiers.oneLine(t, max: 40)}',
        ],
      };
    }

    for (final (t, _) in hits) {
      ToolTiers.markLoaded(t.name);
    }

    return {
      'success': true,
      'tools': [
        for (final (t, _) in hits)
          {
            'name': t.name,
            'description': t.description,
            'parameters': t.inputSchema,
          },
      ],
      'message':
          '取出来了：${hits.map((e) => e.$1.name).join('、')}。'
          '这一轮就能直接调，不用再搜。',
    };
  }
}
