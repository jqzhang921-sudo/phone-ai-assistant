import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../models/book.dart';
import '../models/conversation.dart';
import '../models/diary_entry.dart';
import '../models/letter.dart';
import '../models/memory_topic.dart';
import '../models/musing_entry.dart';

class StorageService {
  static late Directory _dir;
  static const _kBackgroundImageKey = 'chat_background_image_path';
  static const _kBackgroundPresetKey = 'chat_background_preset';

  static Future<void> init() async {
    _dir = await getApplicationDocumentsDirectory();
  }

  /// 保存自定义聊天背景图片路径（传 null 清除）
  static Future<void> setBackgroundImagePath(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_kBackgroundImageKey);
    } else {
      await prefs.setString(_kBackgroundImageKey, path);
    }
  }

  /// 读取自定义聊天背景图片路径，未设置则返回 null
  static Future<String?> getBackgroundImagePath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBackgroundImageKey);
  }

  /// 背景预设：'none' 跟随主题 / 'light' 浅色 / 'dark' 深色
  static Future<void> setBackgroundPreset(String preset) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBackgroundPresetKey, preset);
  }

  static Future<String> getBackgroundPreset() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kBackgroundPresetKey) ?? 'none';
  }

  static String get _convDir => '${_dir.path}/conversations';
  static String get _trashDir => '${_dir.path}/conversations_trash';

  /// ⚠️ **先写临时文件再 rename，不能直接往目标文件上写。**
  ///
  /// 症状是「对话一会消失一会又回来」。原来是 `writeAsString` 直接覆盖目标：
  /// 一段一千多条消息的对话 JSON 将近一兆，写它要花时间，而这期间主页正好去
  /// 列对话，读到的是**半个文件** → `jsonDecode` 抛 → [loadConversation] 返回
  /// null → [listConversations] 把它跳过。写完再刷新，它又出现了。
  ///
  /// 今天起还多了一个写者：后台 isolate 也会往对话里追加主动说的话，
  /// 撞车的窗口比原来更宽。
  ///
  /// `rename` 在同一分区上是原子的：读的人要么看到旧的完整文件，要么看到新的
  /// 完整文件，不存在中间态。写到一半崩了也只是留下一个 .tmp，原文件没动。
  static Future<void> saveConversation(Conversation conv) async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = '$_convDir/${conv.id}.json';
    final tmp = File('$target.tmp');
    await tmp.writeAsString(jsonEncode(conv.toJson()), flush: true);
    await tmp.rename(target);
  }

  static Future<Conversation?> loadConversation(String id) async {
    try {
      final file = File('$_convDir/$id.json');
      if (!await file.exists()) return null;
      final data = await file.readAsString();
      return Conversation.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  /// 上一次 [listConversations] 有几个文件读不出来。
  ///
  /// 原来读失败是**无声跳过**的：那段对话直接从列表里消失，没有报错也没有痕迹，
  /// 用户看到的就是「它突然不见了」——而文件其实还在磁盘上。
  /// 有了原子写之后这个数应该恒为 0；不为 0 就是真出事了，得看得见。
  static int lastListFailures = 0;

  static Future<List<Conversation>> listConversations() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();

    // 清掉崩溃留下的临时文件。它们不参与列表（下面只收 .json），
    // 但留着会越攒越多。
    for (final f in files) {
      if (f.path.endsWith('.json.tmp')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final convs = <Conversation>[];
    var failed = 0;
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversation(
          file.uri.pathSegments.last.replaceAll('.json', ''),
        );
        if (conv != null) {
          convs.add(conv);
        } else {
          // 文件在、但读不出来。以前这里什么都不做，那段对话就无声消失了。
          failed++;
        }
      }
    }
    lastListFailures = failed;
    // 置顶的排最前，其余按更新时间倒序
    convs.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return convs;
  }

  /// 设置对话是否置顶。
  static Future<void> setConversationPinned(String id, bool pinned) async {
    final conv = await loadConversation(id);
    if (conv == null) return;
    conv.isPinned = pinned;
    await saveConversation(conv);
  }

  /// 删除对话：移入回收站（可恢复），而非物理删除。
  static Future<void> deleteConversation(String id) async {
    final src = File('$_convDir/$id.json');
    final trash = File('$_trashDir/$id.json');
    if (await src.exists()) {
      await trash.parent.create(recursive: true);
      await src.rename(trash.path);
    }
  }

  /// 从回收站恢复对话。
  static Future<void> restoreConversation(String id) async {
    final trash = File('$_trashDir/$id.json');
    if (await trash.exists()) {
      await trash.rename('$_convDir/$id.json');
    }
  }

  /// 从回收站彻底删除。
  static Future<void> permanentlyDeleteConversation(String id) async {
    final trash = File('$_trashDir/$id.json');
    if (await trash.exists()) await trash.delete();
  }

  /// 列出回收站中的对话（按更新时间倒序）。
  static Future<List<Conversation>> listTrashedConversations() async {
    final dir = Directory(_trashDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final convs = <Conversation>[];
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversationFromDir(
          _trashDir,
          file.uri.pathSegments.last.replaceAll('.json', ''),
        );
        if (conv != null) convs.add(conv);
      }
    }
    return convs;
  }

  static Future<Conversation?> loadConversationFromDir(
    String dir,
    String id,
  ) async {
    final file = File('$dir/$id.json');
    if (!await file.exists()) return null;
    try {
      final data = await file.readAsString();
      return Conversation.fromJson(jsonDecode(data));
    } catch (_) {
      return null;
    }
  }

  // ---------------- 日记 ----------------
  static const _kDiaryKey = 'diary_entries';

  /// 按时间倒序返回所有日记（最新的在最前）。
  static Future<List<DiaryEntry>> listDiaryEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kDiaryKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => DiaryEntry.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  /// 保存一条新日记（追加，不覆盖旧的）。
  static Future<void> addDiaryEntry(DiaryEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listDiaryEntries();
    entries.add(entry);
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kDiaryKey, raw);
  }

  static Future<void> deleteDiaryEntry(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listDiaryEntries();
    entries.removeWhere((e) => e.id == id);
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await prefs.setString(_kDiaryKey, raw);
  }

  /// 是否已经有当天日期的日记（避免重复生成）。
  static Future<bool> hasDiaryEntryForToday() async {
    final entries = await listDiaryEntries();
    final now = DateTime.now();
    final todayKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return entries.any((e) => e.dateKey == todayKey);
  }

  // ---------------- 我想说（首页每日一段） ----------------
  static const _kTodayMusingKey = 'today_musing';
  static const _kFavoritedMusingsKey = 'favorited_musings';

  static String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  /// 读取今天缓存的"我想说"，格式 {date, content, favorited}。
  /// 如果缓存不是今天的（跨天了），返回 null。
  static Future<Map<String, dynamic>?> getTodayMusing() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kTodayMusingKey);
    if (raw == null) return null;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data['date'] != _todayKey()) return null;
    return data;
  }

  /// 缓存今天新生成的"我想说"（覆盖旧的，用于手动刷新）。
  static Future<void> setTodayMusing(String content) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTodayMusingKey,
      jsonEncode({'date': _todayKey(), 'content': content, 'favorited': false}),
    );
  }

  /// 标记今天缓存的"我想说"是否已收藏（仅影响首页星标显示）。
  static Future<void> setTodayMusingFavorited(bool favorited) async {
    final today = await getTodayMusing();
    if (today == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kTodayMusingKey,
      jsonEncode({...today, 'favorited': favorited}),
    );
  }

  /// 收藏列表：按时间倒序。
  static Future<List<MusingEntry>> listFavoritedMusings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFavoritedMusingsKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => MusingEntry.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Future<void> addFavoritedMusing(MusingEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listFavoritedMusings();
    entries.add(entry);
    await prefs.setString(
      _kFavoritedMusingsKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeFavoritedMusing(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final entries = await listFavoritedMusings();
    entries.removeWhere((e) => e.id == id);
    await prefs.setString(
      _kFavoritedMusingsKey,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }

  /// 今天收藏的"一隅"内容列表（喂给日记生成器做素材，不强制引用）。
  static Future<List<MusingEntry>> listFavoritedMusingsForToday() async {
    final entries = await listFavoritedMusings();
    final todayKey = _todayKey();
    return entries.where((e) => e.dateKey == todayKey).toList();
  }

  // ---------------- 长期记忆（关于用户是谁） ----------------

  /// prefs 的键沿用 `memory_facts`（扁平版留下的名字），**故意不改**：
  /// 改了等于让已有数据和备份文件里的那一段变成孤儿，而且备份白名单
  /// （backup_service 的 _allowedKeys）也得跟着改。键是数据契约，
  /// 类型改名不该波及它。
  static const _kMemoryTopicsKey = 'memory_facts';

  /// 每一类的话题上限。
  ///
  /// 比扁平版的 8 少，是因为话题装得下更多东西：一个话题挂十几条细节，
  /// 不再需要靠条数堆。四类 × 5 条摘要 ≈ 20 行常驻，实际用到的通常只有八九个。
  static const kMaxTopicsPerCategory = 5;

  /// 一个话题底下的细节上限。
  ///
  /// 细节不常驻（要 open_memory 才取），所以可以宽松些；但也不能没有边——
  /// 一个话题攒到几十条，取出来的那一坨自己就成了新的上下文负担。
  static const kMaxDetailsPerTopic = 12;

  /// 全部话题。**顺序必须是稳定的**，不能按「最近更新」排。
  ///
  /// 摘要那一层拼进 system 前缀，靠逐字节不变吃 KV 缓存。要是按更新时间倒序，
  /// 改动任何一条都会把整段重排，等于每次写记忆都把后面几千 token 的历史
  /// 挤出缓存——那正是 b715c47 当初把 memoryContext 挪到消息尾部要避开的事。
  ///
  /// 所以固定用「分类顺序 + 创建时间升序」：新加的只会**追加在本类末尾**，
  /// 前面那些逐字节不动。
  static Future<List<MemoryTopic>> listMemoryTopics() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMemoryTopicsKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => MemoryTopic.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) {
      final byCategory = a.category.index.compareTo(b.category.index);
      if (byCategory != 0) return byCategory;
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  static Future<List<MemoryTopic>> listMemoryTopicsIn(
    MemoryCategory category,
  ) async {
    final all = await listMemoryTopics();
    return all.where((t) => t.category == category).toList();
  }

  static Future<void> _saveMemoryTopics(List<MemoryTopic> topics) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kMemoryTopicsKey,
      jsonEncode(topics.map((t) => t.toJson()).toList()),
    );
  }

  static Future<void> addMemoryTopic(MemoryTopic topic) async {
    final topics = await listMemoryTopics();
    topics.add(topic);
    await _saveMemoryTopics(topics);
  }

  /// 按 id 替换。找不到就什么都不做——**不要顺手插入一条新的**：
  /// 调用方以为自己在改，结果多出一条，比失败更难查。
  static Future<bool> updateMemoryTopic(MemoryTopic topic) async {
    final topics = await listMemoryTopics();
    final i = topics.indexWhere((t) => t.id == topic.id);
    if (i < 0) return false;
    topics[i] = topic;
    await _saveMemoryTopics(topics);
    return true;
  }

  static Future<bool> removeMemoryTopic(String id) async {
    final topics = await listMemoryTopics();
    final before = topics.length;
    topics.removeWhere((t) => t.id == id);
    if (topics.length == before) return false;
    await _saveMemoryTopics(topics);
    return true;
  }

  // ---------------- 信 ----------------
  static const _kLettersKey = 'letters';
  static const _kLastLetterAttemptKey = 'last_letter_attempt_at';
  static const _kLastFavoritePickKey = 'last_favorite_pick_at';

  /// AI 上一次自己挑收藏是什么时候——用来算冷却
  static Future<DateTime?> getLastFavoritePick() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastFavoritePickKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static Future<void> setLastFavoritePick(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastFavoritePickKey, t.toIso8601String());
  }

  /// 按时间倒序（最新的在最前）。
  static Future<List<Letter>> listLetters() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLettersKey);
    if (raw == null) return [];
    final list =
        (jsonDecode(raw) as List)
            .map((e) => Letter.fromJson(e as Map<String, dynamic>))
            .toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Future<void> _writeLetters(List<Letter> letters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLettersKey,
      jsonEncode(letters.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> addLetter(Letter letter) async {
    final letters = await listLetters();
    letters.add(letter);
    await _writeLetters(letters);
  }

  static Future<void> deleteLetter(String id) async {
    final letters = await listLetters();
    letters.removeWhere((e) => e.id == id);
    await _writeLetters(letters);
  }

  static Future<void> markLetterRead(String id) async {
    final letters = await listLetters();
    final idx = letters.indexWhere((e) => e.id == id);
    if (idx < 0 || letters[idx].read) return;
    letters[idx] = letters[idx].copyWith(read: true);
    await _writeLetters(letters);
  }

  /// 未读的 AI 来信数量（给栖息页卡片和底部角标用）。
  static Future<int> unreadLetterCount() async {
    final letters = await listLetters();
    return letters.where((e) => e.isFromAi && !e.read).length;
  }

  /// 上次**尝试**写信的时间——包括 AI 判断「这次没什么可写」而跳过的那次。
  ///
  /// 记「尝试」而不是「发出」是有意的：跳过时如果不记，素材会一直堆在那儿，
  /// 之后每次进栖息页都会重新触发一遍，白白烧 token。
  static Future<DateTime?> getLastLetterAttempt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kLastLetterAttemptKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> setLastLetterAttempt(DateTime t) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastLetterAttemptKey, t.toIso8601String());
  }

  /// 书架的只读视图，给写信时统计素材用。
  ///
  /// 写入归 bookshelf_screen 管，这里只读，所以键名在两处各写了一遍。
  static Future<List<Book>> listBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('bookshelf_books');
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
