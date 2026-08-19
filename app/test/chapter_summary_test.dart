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

    MangaChapterRegistry.remember(
      manga.id,
      121,
      latestNumber: 124,
    );

    expect(manga.chapterDisplayLabel, '124');
    expect(manga.chapterCount, 121);
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

    await cache.writeChapters(
      'anilist:adult|adult:true',
      [externalOnly],
    );

    expect(
      await cache.readChapters('anilist:adult|adult:true'),
      isNull,
    );
    expect(MangaChapterRegistry.summaryFor('anilist:adult'), isNull);
  });

}
