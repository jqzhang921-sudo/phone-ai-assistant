import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/discussion_group.dart';

class DiscussionGroupService {
  static const _storageKey = 'discussion_groups';

  // ── Load / Save ──────────────────────────────────────────

  static Future<List<DiscussionGroup>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((j) => DiscussionGroup.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveAll(List<DiscussionGroup> groups) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _storageKey, jsonEncode(groups.map((g) => g.toJson()).toList()));
  }

  // ── Public API ───────────────────────────────────────────

  /// All groups, newest first
  static Future<List<DiscussionGroup>> listGroups() async {
    final groups = await _loadAll();
    groups.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return groups;
  }

  /// Groups that share at least one book with [bookIds]
  static Future<List<DiscussionGroup>> findGroupsContaining(
      List<String> bookIds) async {
    final all = await _loadAll();
    return all.where((g) => g.overlapsWith(bookIds)).toList()
      ..sort((a, b) {
        // More overlap = higher (more relevant)
        final aOverlap = a.bookIds.where((id) => bookIds.contains(id)).length;
        final bOverlap = b.bookIds.where((id) => bookIds.contains(id)).length;
        return bOverlap.compareTo(aOverlap);
      });
  }

  /// Find a group that covers exactly these books
  static Future<DiscussionGroup?> findExactMatch(
      List<String> bookIds) async {
    final all = await _loadAll();
    for (final g in all) {
      if (g.coversExactly(bookIds)) return g;
    }
    return null;
  }

  /// Create or update a group
  static Future<DiscussionGroup> saveGroup({
    String? id,
    required String name,
    required List<String> bookIds,
  }) async {
    final groups = await _loadAll();
    final now = DateTime.now();

    if (id != null) {
      // Update existing
      final index = groups.indexWhere((g) => g.id == id);
      if (index >= 0) {
        groups[index].name = name;
        groups[index].bookIds = bookIds;
        groups[index].updatedAt = now;
        await _saveAll(groups);
        return groups[index];
      }
    }

    // Create new
    final group = DiscussionGroup(
      id: const Uuid().v4(),
      name: name,
      bookIds: bookIds,
      createdAt: now,
      updatedAt: now,
    );
    groups.add(group);
    await _saveAll(groups);
    return group;
  }

  /// Last message preview for the picker card — 20-30 chars
  static Future<String?> lastMessagePreview(String groupId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final file = File('${appDir.path}/book_conversations/group_$groupId.json');
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      final messages = data['messages'] as List? ?? [];
      if (messages.isEmpty) return null;
      final last = messages.last;
      final content = last['content'] as String? ?? '';
      if (content.isEmpty) return null;
      return content.length > 30 ? '${content.substring(0, 30)}...' : content;
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteGroup(String id) async {
    final groups = await _loadAll();
    groups.removeWhere((g) => g.id == id);
    await _saveAll(groups);
  }
}
