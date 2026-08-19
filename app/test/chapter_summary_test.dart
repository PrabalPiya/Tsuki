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
    );

    MangaChapterRegistry.remember(manga.id, 0, latestNumber: null);

    expect(manga.chapterDisplayLabel, '—');
  });

  test('startup ignores stale pre-V11 adult summaries', () async {
    SharedPreferences.setMockInitialValues({
      'tsuki.chapterSummary.v6.anilist:adult-old|adult:v8': '{"version":6,"mangaId":"anilist:adult-old","count":0,"latestNumber":88}',
      'tsuki.chapterSummary.v6.anilist:adult-v9|adult:v9': '{"version":6,"mangaId":"anilist:adult-v9","count":17,"latestNumber":17}',
      'tsuki.chapterSummary.v6.anilist:adult-v10|adult:v10': '{"version":6,"mangaId":"anilist:adult-v10","count":22,"latestNumber":22}',
    });
    MangaChapterRegistry.clear();

    await ChapterIndexCache.warmGlobalSummaries();

    expect(MangaChapterRegistry.summaryFor('anilist:adult-old'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult-v9'), isNull);
    expect(MangaChapterRegistry.summaryFor('anilist:adult-v10'), isNull);
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
