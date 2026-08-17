class ReadingProgress {
  const ReadingProgress(
      {required this.mangaId,
      required this.chapterId,
      required this.pageIndex,
      required this.relativeOffset,
      required this.chapterProgress,
      this.openedChapterIds = const {},
      required this.updatedAt});
  final String mangaId;
  final String chapterId;
  final int pageIndex;
  final double relativeOffset;
  final double chapterProgress;
  final Set<String> openedChapterIds;
  final DateTime updatedAt;
  Map<String, Object?> toJson() => {
        'mangaId': mangaId,
        'chapterId': chapterId,
        'pageIndex': pageIndex,
        'relativeOffset': relativeOffset,
        'chapterProgress': chapterProgress,
        'openedChapterIds': openedChapterIds.toList(),
        'updatedAt': updatedAt.toIso8601String()
      };
  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final chapterId = json['chapterId'] as String;
    final opened = (json['openedChapterIds'] as List<dynamic>?)
            ?.whereType<String>()
            .toSet() ??
        <String>{chapterId};
    return ReadingProgress(
        mangaId: json['mangaId'] as String,
        chapterId: chapterId,
        pageIndex: json['pageIndex'] as int? ?? 0,
        relativeOffset: (json['relativeOffset'] as num?)?.toDouble() ?? 0,
        chapterProgress: (json['chapterProgress'] as num?)?.toDouble() ?? 0,
        openedChapterIds: opened,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0));
  }
}
