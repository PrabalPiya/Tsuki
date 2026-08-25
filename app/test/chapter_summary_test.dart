import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/storage/chapter_index_cache.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MangaChapterRegistry.clear();
  });

  test('metadata count is provisional until a source index is verified', () {
    const manga = Manga(
      id: 'anilist:1',
      title: 'Example',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 999,
    );

    expect(manga.chapterDisplayLabel, '~999');

    MangaChapterRegistry.remember(manga.id, 121, latestNumber: 124);

    expect(manga.chapterDisplayLabel, '124');
    expect(manga.chapterCount, 121);
  });

  test(
    'empty verification does not replace useful AniList metadata with zero',
    () {
      const manga = Manga(
        id: 'anilist:zero-fallback',
        title: 'Zero fallback',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 73,
      );

      MangaChapterRegistry.remember(manga.id, 0, latestNumber: null);

      expect(manga.hasVerifiedChapterSummary, isFalse);
      expect(manga.chapterDisplayLabel, '~73');
      expect(manga.chapterCount, 73);
    },
  );

  test('unknown metadata stays unknown rather than displaying zero', () {
    const manga = Manga(
      id: 'anilist:unknown',
      title: 'Unknown',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      format: MangaFormat.manga,
    );

    MangaChapterRegistry.remember(manga.id, 0, latestNumber: null);

    expect(manga.chapterDisplayLabel, '—');
  });

  test('cards always have an immediate numeric chapter lower bound', () {
    const ongoing = Manga(
      id: 'anilist:ongoing',
      title: 'Ongoing',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      format: MangaFormat.manga,
    );
    const withVolumes = Manga(
      id: 'anilist:volumes',
      title: 'Known volumes',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      volumeCount: 27,
    );
    const oneShot = Manga(
      id: 'anilist:one-shot',
      title: 'One shot',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.completed,
      chapterCount: 0,
      format: MangaFormat.oneShot,
    );
    const upcoming = Manga(
      id: 'anilist:upcoming',
      title: 'Upcoming',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.notYetReleased,
      chapterCount: 0,
    );

    expect(ongoing.catalogChapterDisplayLabel, '2+');
    expect(withVolumes.catalogChapterDisplayLabel, '20+');
    expect(oneShot.catalogChapterDisplayLabel, '1');
    expect(upcoming.catalogChapterDisplayLabel, '0');
  });

  test('verified chapter summary replaces the immediate fallback', () {
    const manga = Manga(
      id: 'anilist:fallback-upgrade',
      title: 'Fallback upgrade',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      volumeCount: 27,
    );

    expect(manga.catalogChapterDisplayLabel, '20+');

    MangaChapterRegistry.remember(manga.id, 84, latestNumber: 91);

    expect(manga.catalogChapterDisplayLabel, '91');
  });

  test('publication type follows origin metadata', () {
    Manga manga(String id, String? countryCode, {MangaFormat? format}) => Manga(
      id: id,
      title: id,
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      countryCode: countryCode,
      format: format ?? MangaFormat.manga,
    );

    expect(manga('jp', 'JP').publicationTypeLabel, 'Manga');
    expect(manga('kr', 'KR').publicationTypeLabel, 'Manhwa');
    expect(manga('cn', 'CN').publicationTypeLabel, 'Manhua');
    expect(manga('tw', 'TW').publicationTypeLabel, 'Manhua');
    expect(
      manga('novel', 'KR', format: MangaFormat.novel).publicationTypeLabel,
      'Novel',
    );
  });

  test('startup ignores stale pre-release adult summaries', () async {
    SharedPreferences.setMockInitialValues({
      'tsuki.chapterSummary.v6.anilist:adult-old|adult:v8': '{"version":6,"mangaId":"anilist:adult-old","count":0,"latestNumber":88}',
      'tsuki.chapterSummary.v6.anilist:adult-v9|adult:v9': '{"version":6,"mangaId":"anilist:adult-v9","count":17,"latestNumber":17}',
      'tsuki.chapterSummary.v6.anilist:adult-v10|adult:v10': '{"version":6,"mangaId":"anilist:adult-v10","count":22,"latestNumber":22}',
      'tsuki.chapterSummary.v6.anilist:adult-v11|adult:v11': '{"version":6,"mangaId":"anilist:adult-v11","count":30,"latestNumber":30}',
    });
    MangaChapterRegistry.clear();

    await ChapterIndexCache.warmGlobalSummaries();

    expect(MangaChapterRegistry.summaryFor('anilist:adult-old'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult-v9'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult-v10'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult-v11'), isNull);
  });

  test('verified latest chapter survives app-style cache warm-up', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = ChapterIndexCache(preferences: Future.value(prefs));
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);

    final chapters = <CanonicalChapter>[
      CanonicalChapter(
        id: 'chapter:number:1',
        number: 1,
        title: 'Chapter 1',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'test',
            chapterId: '1',
            reliability: 1,
            publishedAt: epoch,
          ),
        ],
      ),
      CanonicalChapter(
        id: 'chapter:number:124',
        number: 124,
        title: 'Chapter 124',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'test',
            chapterId: '124',
            reliability: 1,
            publishedAt: epoch,
          ),
        ],
      ),
    ];

    await cache.writeChapters('anilist:2|adult:false', chapters);
    MangaChapterRegistry.clear();

    await ChapterIndexCache.warmGlobalSummaries();

    expect(MangaChapterRegistry.displayLabelFor('anilist:2'), '124');
    expect(MangaChapterRegistry.countFor('anilist:2'), 2);
  });

  test('current safe cache keys restore the canonical manga summary', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = ChapterIndexCache(preferences: Future.value(prefs));
    const summary = MangaChapterSummary(indexCount: 0, latestNumber: 88);

    await cache.writeSummary(
      'anilist:88',
      summary,
      cacheKey: 'anilist:88|safe',
    );
    MangaChapterRegistry.clear();

    await ChapterIndexCache.warmGlobalSummaries();

    expect(MangaChapterRegistry.displayLabelFor('anilist:88'), '88');
  });
  test('external-only chapter metadata is not persisted as readable', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = ChapterIndexCache(preferences: Future.value(prefs));
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);

    final externalOnly = CanonicalChapter(
      id: 'chapter:number:50',
      number: 50,
      title: 'Chapter 50',
      publishedAt: epoch,
      sourceCopies: [
        ChapterSourceCopy(
          sourceId: 'mangadex',
          chapterId: 'external-50',
          reliability: .35,
          publishedAt: epoch,
          externalUrl: 'https://example.com/chapter-50',
        ),
      ],
    );

    await cache.writeChapters('anilist:adult|adult:true', [externalOnly]);

    expect(await cache.readChapters('anilist:adult|adult:true'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult'), isNull);
  });
}
