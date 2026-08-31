import 'chapter.dart';

class ReadingProgress {
  const ReadingProgress({
    required this.mangaId,
    required this.chapterId,
    required this.pageIndex,
    required this.relativeOffset,
    required this.chapterProgress,
    this.openedChapterIds = const {},
    this.rawChapter,
    this.normalizedChapterNumber,
    required this.updatedAt,
  });
  final String mangaId;
  final String chapterId;
  final int pageIndex;
  final double relativeOffset;
  final double chapterProgress;
  final Set<String> openedChapterIds;
  final String? rawChapter;
  final double? normalizedChapterNumber;
  final DateTime updatedAt;
  Map<String, Object?> toJson() => {
    'mangaId': mangaId,
    'chapterId': chapterId,
    'pageIndex': pageIndex,
    'relativeOffset': relativeOffset,
    'chapterProgress': chapterProgress,
    'openedChapterIds': openedChapterIds.toList(),
    'rawChapter': rawChapter,
    'normalizedChapterNumber': normalizedChapterNumber,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final chapterId = json['chapterId'] as String;
    final opened =
        (json['openedChapterIds'] as List<dynamic>?)
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
      rawChapter: json['rawChapter']?.toString(),
      normalizedChapterNumber: (json['normalizedChapterNumber'] as num?)
          ?.toDouble(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

bool isReadingCaughtUp(
  ReadingProgress? progress,
  List<CanonicalChapter> chapters,
) {
  if (progress == null || chapters.isEmpty) return false;

  CanonicalChapter? latestNumbered;
  CanonicalChapter? latestDated;
  CanonicalChapter? highestViewedNumbered;
  CanonicalChapter? current;
  final viewedIds = {...progress.openedChapterIds, progress.chapterId};

  for (final chapter in chapters) {
    final number = chapter.number;
    if (number != null &&
        (latestNumbered == null || number > latestNumbered.number!)) {
      latestNumbered = chapter;
    }
    if (latestDated == null ||
        chapter.publishedAt.isAfter(latestDated.publishedAt)) {
      latestDated = chapter;
    }

    if (chapter.id == progress.chapterId) current = chapter;
    if (!viewedIds.contains(chapter.id) || number == null) continue;
    if (highestViewedNumbered == null ||
        number > highestViewedNumbered.number!) {
      highestViewedNumbered = chapter;
    }
  }

  final latest = latestNumbered ?? latestDated;
  if (latest == null) return false;

  final viewed = highestViewedNumbered ?? current;
  final viewedNumber = viewed?.number;
  final savedNumber =
      progress.normalizedChapterNumber ??
      _chapterNumberFromId(progress.chapterId);
  final latestNumber = latest.number;
  if (latestNumber != null) {
    final highestReadNumber = switch ((viewedNumber, savedNumber)) {
      (final double viewed, final double saved) =>
        viewed > saved ? viewed : saved,
      (final double viewed, null) => viewed,
      (null, final double saved) => saved,
      _ => null,
    };
    if (highestReadNumber != null) {
      return highestReadNumber >= latestNumber - 0.000001;
    }
  }
  return viewed != null && _sameOrLaterChapter(viewed, latest);
}

bool _sameOrLaterChapter(CanonicalChapter viewed, CanonicalChapter latest) {
  if (viewed.id == latest.id) return true;
  final viewedNumber = viewed.number;
  final latestNumber = latest.number;
  if (viewedNumber != null && latestNumber != null) {
    return viewedNumber >= latestNumber - 0.000001;
  }
  return viewed.numberLabel.trim().toLowerCase() ==
      latest.numberLabel.trim().toLowerCase();
}

double? _chapterNumberFromId(String chapterId) {
  final match = RegExp(r'(?:^|:)number:([0-9]+(?:\.[0-9]+)?)$')
      .firstMatch(chapterId);
  return match == null ? null : double.tryParse(match.group(1)!);
}
