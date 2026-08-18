import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';

void main() {
  test('canonical chapter can retain multiple source copies', () {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);

    final chapter = CanonicalChapter(
      id: 'chapter:number:12.5',
      number: 12.5,
      title: 'Chapter 12.5',
      publishedAt: epoch,
      sourceCopies: [
        ChapterSourceCopy(
          sourceId: 'mangadex',
          chapterId: 'mangadex-a',
          reliability: .90,
          publishedAt: epoch,
        ),
        ChapterSourceCopy(
          sourceId: 'comick',
          chapterId: 'comick-b',
          reliability: .78,
          publishedAt: epoch,
        ),
        ChapterSourceCopy(
          sourceId: 'mangapill',
          chapterId: 'mangapill-c',
          reliability: .66,
          publishedAt: epoch,
        ),
      ],
    );

    expect(chapter.numberLabel, '12.5');

    expect(chapter.sourceCopies, hasLength(3));

    expect(
      chapter.sourceCopies.map((copy) => copy.sourceId),
      containsAll(['mangadex', 'comick', 'mangapill']),
    );
  });

  test('adult manga remains identifiable for source gating', () {
    const manga = Manga(
      id: 'anilist:1',
      title: 'Adult Test Manga',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
      isAdult: true,
    );

    expect(manga.isAdult, isTrue);
  });
}
