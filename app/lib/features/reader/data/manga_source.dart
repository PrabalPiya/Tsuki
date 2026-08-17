import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';

class SourceCapabilities {
  const SourceCapabilities(
      {this.search = false,
      this.details = false,
      this.chapters = false,
      this.pages = false,
      this.updates = false,
      this.officialUrl = false});
  final bool search, details, chapters, pages, updates, officialUrl;
}

abstract interface class MangaSource {
  String get id;
  String get displayName;
  SourceCapabilities get capabilities;
  Set<String> get allowedImageHosts;
  Future<List<Manga>> search(String query);
  Future<Manga?> getMangaDetails(String sourceMangaId);
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId);
  Future<ChapterPages> getChapterPages(String sourceChapterId);
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId);
}
