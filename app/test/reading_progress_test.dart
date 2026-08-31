import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/reading_progress.dart';

void main() {
  test(
    'imported chapter number marks a differently keyed latest chapter read',
    () {
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final chapters = [
        CanonicalChapter(
          id: 'chapter:number:12-from-live-source',
          number: 12,
          title: 'Chapter 12',
          publishedAt: epoch,
          sourceCopies: [
            ChapterSourceCopy(
              sourceId: 'test',
              chapterId: '12',
              reliability: 1,
              publishedAt: epoch,
            ),
          ],
        ),
      ];
      final progress = ReadingProgress(
        mangaId: 'manga:1',
        chapterId: 'chapter:import:Ch. 12',
        pageIndex: 0,
        relativeOffset: 0,
        chapterProgress: 1,
        normalizedChapterNumber: 12,
        updatedAt: epoch,
      );

      expect(isReadingCaughtUp(progress, chapters), isTrue);
    },
  );

  test('an imported older chapter is not caught up', () {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final chapters = [
      CanonicalChapter(
        id: 'chapter:number:13',
        number: 13,
        title: 'Chapter 13',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'test',
            chapterId: '13',
            reliability: 1,
            publishedAt: epoch,
          ),
        ],
      ),
    ];
    final progress = ReadingProgress(
      mangaId: 'manga:1',
      chapterId: 'chapter:import:Ch. 12',
      pageIndex: 0,
      relativeOffset: 0,
      chapterProgress: 1,
      normalizedChapterNumber: 12,
      updatedAt: epoch,
    );

    expect(isReadingCaughtUp(progress, chapters), isFalse);
  });
}
