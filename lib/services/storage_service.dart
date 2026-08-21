import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../models/book.dart';
import '../models/conversation.dart';
import '../models/diary_entry.dart';
import '../models/letter.dart';
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

  static Future<void> saveConversation(Conversation conv) async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('$_convDir/${conv.id}.json');
    await file.writeAsString(jsonEncode(conv.toJson()));
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

  static Future<List<Conversation>> listConversations() async {
    final dir = Directory(_convDir);
    if (!await dir.exists()) return [];
    final files = await dir.list().toList();
    files.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final convs = <Conversation>[];
    for (final file in files) {
      if (file.path.endsWith('.json')) {
        final conv = await loadConversation(
          file.uri.pathSegments.last.replaceAll('.json', ''),
        );
        if (conv != null) convs.add(conv);
      }
    }
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
