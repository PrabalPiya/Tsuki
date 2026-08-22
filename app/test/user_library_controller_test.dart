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
  final bookmarkWrites = <Set<String>>[];
  final progressWrites = <ReadingProgress>[];
  Completer<void>? bookmarkGate;
  Completer<void>? progressGate;

  @override
  Future<UserSnapshot> load(String uid) async =>
      const UserSnapshot(bookmarks: {}, bookmarkedManga: {}, progress: {});

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
}
