import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import '../models/conversation.dart';
import '../models/diary_entry.dart';

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
    return convs;
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
}
