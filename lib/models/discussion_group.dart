class DiscussionGroup {
  final String id;
  String name;
  List<String> bookIds;
  final DateTime createdAt;
  DateTime updatedAt;

  DiscussionGroup({
    required this.id,
    required this.name,
    required this.bookIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// The conversation file is keyed by the group's own UUID — never changes,
  /// even when bookIds are added or removed later.
  String get conversationId => 'group_$id';

  /// Human-readable book count label
  String get bookCountLabel => '${bookIds.length}本书';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'bookIds': bookIds,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory DiscussionGroup.fromJson(Map<String, dynamic> json) =>
      DiscussionGroup(
        id: json['id'],
        name: json['name'],
        bookIds: List<String>.from(json['bookIds'] ?? []),
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
      );

  /// Does this group cover exactly the given books? (same set, order-insensitive)
  bool coversExactly(List<String> ids) {
    if (ids.length != bookIds.length) return false;
    return ids.toSet().containsAll(bookIds) && bookIds.toSet().containsAll(ids);
  }

  /// Does this group share at least one book with the given list?
  bool overlapsWith(List<String> ids) =>
      bookIds.any((b) => ids.contains(b));
}
