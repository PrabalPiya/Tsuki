class ChapterSourceCopy {
  const ChapterSourceCopy(
      {required this.sourceId,
      required this.chapterId,
      required this.reliability,
      required this.publishedAt,
      this.attribution,
      this.externalUrl});
  final String sourceId;
  final String chapterId;
  final double reliability;
  final DateTime publishedAt;
  final String? attribution;
  final String? externalUrl;
  bool get isDirectlyReadable => externalUrl == null;
}

class CanonicalChapter {
  const CanonicalChapter(
      {required this.id,
      required this.number,
      required this.title,
      required this.publishedAt,
      required this.sourceCopies});
  final String id;
  final double? number;
  final String title;
  final DateTime publishedAt;
  final List<ChapterSourceCopy> sourceCopies;
  bool get hasDirectlyReadableCopy =>
      sourceCopies.any((copy) => copy.isDirectlyReadable);
  String get numberLabel {
    final value = number;
    if (value == null) return title;
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
}

class ChapterPages {
  const ChapterPages(
      {required this.chapterId, required this.sourceId, required this.urls});
  final String chapterId;
  final String sourceId;
  final List<String> urls;
}
