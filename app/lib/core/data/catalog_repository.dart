import '../config/app_config.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/search/data/metadata_provider.dart';
import '../../shared/demo_catalog.dart';

class CatalogRepository {
  CatalogRepository(
      {required AppConfig config,
      required MetadataProvider metadata,
      required MangaDexSource mangaDex})
      : _config = config,
        _metadata = metadata,
        _mangaDex = mangaDex {
    if (config.useDemoData) {
      for (final manga in demoCatalog) {
        _cache[manga.id] = manga;
      }
    }
  }
  final AppConfig _config;
  final MetadataProvider _metadata;
  final MangaDexSource _mangaDex;
  final Map<String, Manga> _cache = {};
  final Map<String, List<CanonicalChapter>> _chapterCache = {};
  List<Manga> get demoRankings => _config.useDemoData ? demoCatalog : const [];
  Manga? cached(String id) => _cache[id];
  void remember(Manga manga) => _cache[manga.id] = manga;
  Future<List<Manga>> search(String query, {required bool includeAdult}) async {
    if (query.trim().length < 2) return const [];
    try {
      final values =
          await _metadata.search(query.trim(), includeAdult: includeAdult);
      for (final value in values) {
        _cache[value.id] = value;
      }
      return _dedupe(values);
    } catch (_) {
      if (!_config.useDemoData) rethrow;
      final q = query.toLowerCase();
      return demoCatalog
          .where((m) => m.title.toLowerCase().contains(q))
          .toList();
    }
  }

  Future<Manga?> details(String id) async {
    final value = _cache[id];
    if (value != null) return value;
    final loaded = await _metadata.getById(id);
    if (loaded != null) _cache[id] = loaded;
    return loaded;
  }

  Future<List<CanonicalChapter>> chapters(Manga manga,
      {bool refresh = false}) async {
    if (!refresh && _chapterCache.containsKey(manga.id)) {
      return _chapterCache[manga.id]!;
    }
    if (manga.id.startsWith('demo:')) {
      return _chapterCache[manga.id] = demoChapters(manga);
    }
    try {
      final sourceId =
          manga.mangaDexId ?? await _mangaDex.findConservativeMatch(manga);
      if (sourceId == null) return const [];
      final result = await _mangaDex.getChapters(sourceId);
      _cache[manga.id] =
          manga.copyWith(mangaDexId: sourceId, chapterCount: result.length);
      return _chapterCache[manga.id] = result;
    } catch (_) {
      if (!_config.useDemoData) rethrow;
      return _chapterCache[manga.id] = demoChapters(manga);
    }
  }

  Future<ChapterPages> pages(CanonicalChapter chapter) async {
    final copies = [...chapter.sourceCopies]
      ..sort((a, b) => b.reliability.compareTo(a.reliability));
    Object? last;
    for (final copy in copies) {
      try {
        if (copy.sourceId == 'demo') return demoPages(copy.chapterId);
        if (copy.sourceId == _mangaDex.id) {
          if (!copy.isDirectlyReadable) continue;
          return await _mangaDex.getChapterPages(copy.chapterId);
        }
      } catch (e) {
        last = e;
      }
    }
    throw last ?? StateError('Chapter unavailable right now.');
  }

  List<Manga> _dedupe(List<Manga> values) {
    final map = <String, Manga>{};
    for (final m in values) {
      map.putIfAbsent(m.anilistId?.toString() ?? _normalize(m.title), () => m);
    }
    return map.values.toList();
  }

  String _normalize(String v) =>
      v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
