class ReadingProfile {
  final String bookId;
  final DateTime generatedAt;
  final List<String> coreOpinions;
  final List<String> unresolvedQuestions;
  final String discussionSummary;

  ReadingProfile({
    required this.bookId,
    required this.coreOpinions,
    required this.unresolvedQuestions,
    required this.discussionSummary,
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  bool get isEmpty =>
      coreOpinions.isEmpty &&
      unresolvedQuestions.isEmpty &&
      discussionSummary.isEmpty;

  factory ReadingProfile.empty(String bookId) => ReadingProfile(
        bookId: bookId,
        coreOpinions: [],
        unresolvedQuestions: [],
        discussionSummary: '',
      );

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'generatedAt': generatedAt.toIso8601String(),
        'coreOpinions': coreOpinions,
        'unresolvedQuestions': unresolvedQuestions,
        'discussionSummary': discussionSummary,
      };

  factory ReadingProfile.fromJson(Map<String, dynamic> json) =>
      ReadingProfile(
        bookId: json['bookId'],
        generatedAt: DateTime.parse(json['generatedAt']),
        coreOpinions: List<String>.from(json['coreOpinions'] ?? []),
        unresolvedQuestions:
            List<String>.from(json['unresolvedQuestions'] ?? []),
        discussionSummary: json['discussionSummary'] ?? '',
      );
}
