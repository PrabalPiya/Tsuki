import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/models/reading_progress.dart';
import 'package:tsuki/core/state/app_state.dart';
import 'package:tsuki/core/storage/user_store.dart';

const _firstManga = Manga(
  id: 'manga:one',
  title: 'One',
  coverUrl: '',
  synopsis: 'A safe test manga.',
  status: MangaStatus.ongoing,
  chapterCount: 1,
);

const _secondManga = Manga(
  id: 'manga:two',
  title: 'Two',
  coverUrl: '',
  synopsis: 'Another safe test manga.',
  status: MangaStatus.ongoing,
  chapterCount: 1,
);

class _ControlledStore implements UserStore {
  _ControlledStore({
    this.initial = const UserSnapshot(
      bookmarks: {},
      bookmarkedManga: {},
      progress: {},
    ),
  });

  final UserSnapshot initial;
  final bookmarkWrites = <Set<String>>[];
  final progressWrites = <ReadingProgress>[];
  Completer<void>? bookmarkGate;
  Completer<void>? progressGate;

  @override
  Future<UserSnapshot> load(String uid) async => initial;

  @override
  Future<void> saveBookmarks(
    String uid,
    Set<String> ids,
    Map<String, Manga> manga,
  ) async {
    bookmarkWrites.add({...ids});
    final gate = bookmarkGate;
    bookmarkGate = null;
    await gate?.future;
  }

  @override
  Future<void> saveProgress(String uid, ReadingProgress progress) async {
    progressWrites.add(progress);
    final gate = progressGate;
    progressGate = null;
    await gate?.future;
  }

  @override
  Future<void> clearSession(String uid) async {}
}

ReadingProgress _progress(int page) => ReadingProgress(
  mangaId: _firstManga.id,
  chapterId: 'chapter-1',
  pageIndex: page,
  relativeOffset: .5,
  chapterProgress: page / 10,
  updatedAt: DateTime(2026, 1, 1, 0, page),
);

void main() {
  test(
    'rapid bookmark changes persist the first and latest snapshots',
    () async {
      final store = _ControlledStore();
      final gate = Completer<void>();
      store.bookmarkGate = gate;
      final controller = UserLibraryController('reader', store);
      await Future<void>.delayed(Duration.zero);

      final first = controller.toggleBookmark(_firstManga);
      final second = controller.toggleBookmark(_secondManga);
      final third = controller.toggleBookmark(_firstManga);

      expect(controller.state.bookmarks, {_secondManga.id});
      expect(store.bookmarkWrites, [
        {_firstManga.id},
      ]);

      gate.complete();
      await Future.wait([first, second, third]);

      expect(store.bookmarkWrites, [
        {_firstManga.id},
        {_secondManga.id},
      ]);
      controller.dispose();
    },
  );

  test(
    'rapid reading progress writes coalesce to the newest position',
    () async {
      final store = _ControlledStore();
      final gate = Completer<void>();
      store.progressGate = gate;
      final controller = UserLibraryController('reader', store);
      await Future<void>.delayed(Duration.zero);

      final first = controller.saveProgress(_progress(1));
      final second = controller.saveProgress(_progress(2));
      final third = controller.saveProgress(_progress(3));

      expect(controller.state.progress[_firstManga.id]?.pageIndex, 3);
      expect(store.progressWrites.map((value) => value.pageIndex), [1]);

      gate.complete();
      await Future.wait([first, second, third]);

      expect(store.progressWrites.map((value) => value.pageIndex), [1, 3]);
      controller.dispose();
    },
  );

  test('removes multiple bookmarks in one state update', () async {
    final store = _ControlledStore();
    final controller = UserLibraryController('reader', store);
    await Future<void>.delayed(Duration.zero);

    await controller.importBatch({
      _firstManga.id: _firstManga,
      _secondManga.id: _secondManga,
    }, const {});
    store.bookmarkWrites.clear();

    await controller.removeBookmarks([
      _firstManga.id,
      _secondManga.id,
      'missing',
    ]);

    expect(controller.state.bookmarks, isEmpty);
    expect(controller.state.bookmarkedManga, isEmpty);
    expect(store.bookmarkWrites, [<String>{}]);
    controller.dispose();
  });

  test(
    'repeated migration merges manga and progress into one bookmark',
    () async {
      final store = _ControlledStore();
      final controller = UserLibraryController('reader', store);
      await Future<void>.delayed(Duration.zero);
      await controller.restoreBookmark(_firstManga);
      const duplicate = Manga(
        id: 'anilist:duplicate-one',
        anilistId: 101,
        title: 'One [Ongoing]',
        coverUrl: '',
        synopsis: 'Updated metadata.',
        status: MangaStatus.ongoing,
        chapterCount: 5,
      );
      final importedProgress = ReadingProgress(
        mangaId: duplicate.id,
        chapterId: 'chapter:number:5',
        pageIndex: 0,
        relativeOffset: 0,
        chapterProgress: 1,
        normalizedChapterNumber: 5,
        updatedAt: DateTime(2026, 8, 31),
      );

      await controller.importBatch(
        {duplicate.id: duplicate},
        {duplicate.id: importedProgress},
      );

      expect(controller.state.bookmarks, {_firstManga.id});
      expect(controller.state.bookmarkedManga, hasLength(1));
      expect(controller.state.bookmarkedManga[_firstManga.id]?.anilistId, 101);
      expect(
        controller.state.progress[_firstManga.id]?.chapterId,
        'chapter:number:5',
      );
      expect(controller.state.progress, isNot(contains(duplicate.id)));
      controller.dispose();
    },
  );

  test(
    'startup repairs duplicate migrated bookmarks and keeps furthest progress',
    () async {
      const duplicate = Manga(
        id: 'anilist:old-duplicate',
        anilistId: 202,
        title: 'One [Completed]',
        coverUrl: '',
        synopsis: 'Duplicate migrated metadata.',
        status: MangaStatus.completed,
        chapterCount: 8,
      );
      final earlier = ReadingProgress(
        mangaId: _firstManga.id,
        chapterId: 'chapter:number:3',
        pageIndex: 0,
        relativeOffset: 0,
        chapterProgress: 1,
        normalizedChapterNumber: 3,
        updatedAt: DateTime(2026, 1, 1),
      );
      final later = ReadingProgress(
        mangaId: duplicate.id,
        chapterId: 'chapter:number:8',
        pageIndex: 0,
        relativeOffset: 0,
        chapterProgress: 1,
        normalizedChapterNumber: 8,
        updatedAt: DateTime(2026, 2, 1),
      );
      final store = _ControlledStore(
        initial: UserSnapshot(
          bookmarks: {_firstManga.id, duplicate.id},
          bookmarkedManga: {
            _firstManga.id: _firstManga,
            duplicate.id: duplicate,
          },
          progress: {_firstManga.id: earlier, duplicate.id: later},
        ),
      );
      final controller = UserLibraryController('reader', store);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(controller.currentState.bookmarks, {_firstManga.id});
      expect(controller.currentState.bookmarkedManga, hasLength(1));
      expect(
        controller
            .currentState
            .progress[_firstManga.id]
            ?.normalizedChapterNumber,
        8,
      );
      expect(controller.currentState.progress, isNot(contains(duplicate.id)));
      controller.dispose();
    },
  );
}
