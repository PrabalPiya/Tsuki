import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/storage/chapter_index_cache.dart';
import 'package:tsuki/features/reader/data/asura_source.dart';
import 'package:tsuki/features/reader/data/demonic_scans_source.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/reader/data/manganato_source.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';

void main() {
  setUp(MangaChapterRegistry.clear);

  test(
    'quick refresh chooses the highest chapter instead of first response',
    () async {
      final cache = _StaleChapterCache([_chapter(90, 'mangadex')]);
      final mangaDex = _MangaDexAt150();
      final demonicScans = _DemonicScansAt100();
      final repository = CatalogRepository(
        config: _config,
        metadata: _Metadata(),
        mangaDex: mangaDex,
        demonicScans: demonicScans,
        manganato: _NoManganato(),
        asura: _NoAsura(),
        chapterIndexCache: cache,
      );
      const manga = Manga(
        id: 'anilist:freshness',
        mangaDexId: 'mangadex-id',
        title: 'Freshness',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      );

      final refreshed = await repository.refreshChapters(manga);

      expect(refreshed.map((chapter) => chapter.number), contains(150));
      expect(MangaChapterRegistry.latestNumberFor(manga.id), 150);
      expect(mangaDex.fullIndexLoads, 1);
      expect(demonicScans.fullIndexLoads, 0);
    },
  );

  test('a visible card refreshes its exact chapter summary', () async {
    final cache = _StaleChapterCache(const []);
    final mangaDex = _MangaDexAt150();
    final repository = CatalogRepository(
      config: _config,
      metadata: _Metadata(),
      mangaDex: mangaDex,
      demonicScans: _DemonicScansAt100(),
      manganato: _NoManganato(),
      asura: _NoAsura(),
      chapterIndexCache: cache,
    );
    const manga = Manga(
      id: 'anilist:card-summary',
      mangaDexId: 'mangadex-id',
      title: 'Card summary',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
    );
    final updated = repository.chapterUpdates.firstWhere(
      (mangaId) => mangaId == manga.id,
    );

    repository.queueChapterSummaryWarmup(manga);
    await updated.timeout(const Duration(seconds: 2));

    expect(manga.catalogChapterDisplayLabel, '150');
    expect(mangaDex.fullIndexLoads, 0);
  });

  test(
    'a newer card summary updates an existing stale chapter index',
    () async {
      final cache = _StaleChapterCache([_chapter(90, 'mangadex')]);
      final mangaDex = _MangaDexAt150();
      final repository = CatalogRepository(
        config: _config,
        metadata: _Metadata(),
        mangaDex: mangaDex,
        demonicScans: _DemonicScansAt100(),
        manganato: _NoManganato(),
        asura: _NoAsura(),
        chapterIndexCache: cache,
      );
      const manga = Manga(
        id: 'anilist:card-index-refresh',
        mangaDexId: 'mangadex-id',
        title: 'Card index refresh',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      );
      final updates = repository.chapterUpdates
          .where((mangaId) => mangaId == manga.id)
          .take(2)
          .toList();

      repository.queueChapterSummaryWarmup(manga);
      await updates.timeout(const Duration(seconds: 2));

      final memory = repository.memoryChapters(manga);
      expect(memory?.map((chapter) => chapter.number), contains(150));
      expect(mangaDex.fullIndexLoads, 1);
    },
  );

  test(
    'a current card summary still repairs an older cached chapter index',
    () async {
      final cache = _StaleChapterCache([_chapter(90, 'mangadex')]);
      final mangaDex = _MangaDexAt150();
      final repository = CatalogRepository(
        config: _config,
        metadata: _Metadata(),
        mangaDex: mangaDex,
        demonicScans: _DemonicScansAt100(),
        manganato: _NoManganato(),
        asura: _NoAsura(),
        chapterIndexCache: cache,
      );
      const manga = Manga(
        id: 'anilist:current-summary-stale-index',
        mangaDexId: 'mangadex-id',
        title: 'Current summary stale index',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      );
      MangaChapterRegistry.rememberSummary(
        manga.id,
        const MangaChapterSummary(indexCount: 90, latestNumber: 150),
      );
      final updated = repository.chapterUpdates.firstWhere(
        (mangaId) => mangaId == manga.id,
      );

      repository.queueChapterSummaryWarmup(manga);
      await updated.timeout(const Duration(seconds: 2));

      final memory = repository.memoryChapters(manga);
      expect(memory?.map((chapter) => chapter.number), contains(150));
      expect(mangaDex.fullIndexLoads, 1);
    },
  );
}

const _config = AppConfig(
  environment: AppEnvironment.development,
  useDemoData: false,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
  remoteCatalogUrl: '',
);

CanonicalChapter _chapter(double number, String source) {
  final publishedAt = DateTime.utc(
    2026,
    1,
    1,
  ).add(Duration(days: number.toInt()));
  return CanonicalChapter(
    id: 'chapter:number:$number',
    number: number,
    title: 'Chapter $number',
    publishedAt: publishedAt,
    sourceCopies: [
      ChapterSourceCopy(
        sourceId: source,
        chapterId: '$source-$number',
        reliability: .9,
        publishedAt: publishedAt,
      ),
    ],
  );
}

class _StaleChapterCache extends ChapterIndexCache {
  _StaleChapterCache(this.chapters);

  final List<CanonicalChapter> chapters;

  @override
  Future<List<CanonicalChapter>?> readChapters(String cacheKey) async =>
      chapters;

  @override
  Future<bool> isStale(
    String cacheKey,
    Duration maxAge, {
    bool deep = false,
  }) async => !deep;

  @override
  Future<void> writeChapters(
    String cacheKey,
    List<CanonicalChapter> chapters, {
    bool markChecked = false,
    bool markDeepChecked = false,
  }) async {}

  @override
  Future<void> writeSummary(
    String mangaId,
    MangaChapterSummary summary, {
    String? cacheKey,
  }) async {
    MangaChapterRegistry.rememberSummary(mangaId, summary);
  }
}

class _Metadata implements MetadataProvider {
  @override
  String get id => 'test';

  @override
  Future<Manga?> getById(String id) async => null;

  @override
  Future<List<Manga>> search(String query) async => const [];
}

class _MangaDexAt150 extends MangaDexSource {
  int fullIndexLoads = 0;

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return _chapter(150, id);
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    fullIndexLoads++;
    return [_chapter(150, id)];
  }
}

class _DemonicScansAt100 extends DemonicScansSource {
  int fullIndexLoads = 0;

  @override
  Future<String?> findConservativeMatch(Manga canonical) async => 'demonic-id';

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async =>
      _chapter(100, id);

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    fullIndexLoads++;
    return [_chapter(100, id)];
  }
}

class _NoAsura extends AsuraSource {
  @override
  Future<String?> findConservativeMatch(Manga canonical) async => null;
}

class _NoManganato extends ManganatoSource {
  @override
  Future<String?> findConservativeMatch(Manga canonical) async => null;
}
