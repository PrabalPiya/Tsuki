import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/manga.dart';
import '../models/reading_progress.dart';
import '../storage/user_store.dart';

class UserLibraryState {
  const UserLibraryState({
    this.loading = true,
    this.bookmarks = const {},
    this.bookmarkedManga = const {},
    this.progress = const {},
  });

  final bool loading;
  final Set<String> bookmarks;
  final Map<String, Manga> bookmarkedManga;
  final Map<String, ReadingProgress> progress;

  UserLibraryState copyWith({
    bool? loading,
    Set<String>? bookmarks,
    Map<String, Manga>? bookmarkedManga,
    Map<String, ReadingProgress>? progress,
  }) => UserLibraryState(
    loading: loading ?? this.loading,
    bookmarks: bookmarks ?? this.bookmarks,
    bookmarkedManga: bookmarkedManga ?? this.bookmarkedManga,
    progress: progress ?? this.progress,
  );
}

class UserLibraryController extends StateNotifier<UserLibraryState> {
  UserLibraryController(this._uid, this._store)
    : super(const UserLibraryState()) {
    _load();
  }

  final String _uid;
  final UserStore _store;

  Future<void> _load() async {
    final value = await _store.load(_uid);
    state = UserLibraryState(
      loading: false,
      bookmarks: value.bookmarks,
      bookmarkedManga: value.bookmarkedManga,
      progress: value.progress,
    );
  }

  Future<void> toggleBookmark(Manga manga) async {
    if (manga.isAdult) return;
    final next = {...state.bookmarks};
    final metadata = {...state.bookmarkedManga};
    if (!next.add(manga.id)) {
      next.remove(manga.id);
      metadata.remove(manga.id);
    } else {
      metadata[manga.id] = manga;
    }
    state = state.copyWith(bookmarks: next, bookmarkedManga: metadata);
    try {
      await _store.saveBookmarks(_uid, next, metadata);
    } catch (_) {
      // Firestore may be temporarily offline; local state is already durable.
    }
  }

  Future<void> restoreBookmark(Manga manga) async {
    if (manga.isAdult) return;
    final next = {...state.bookmarks, manga.id};
    final metadata = {...state.bookmarkedManga, manga.id: manga};
    state = state.copyWith(bookmarks: next, bookmarkedManga: metadata);
    try {
      await _store.saveBookmarks(_uid, next, metadata);
    } catch (_) {
      // Firestore may be temporarily offline; local state is already durable.
    }
  }

  Future<void> saveProgress(ReadingProgress value) async {
    final previous = state.progress[value.mangaId];
    final normalized = ReadingProgress(
      mangaId: value.mangaId,
      chapterId: value.chapterId,
      pageIndex: value.pageIndex,
      relativeOffset: value.relativeOffset,
      chapterProgress: value.chapterProgress,
      openedChapterIds: {
        ...?previous?.openedChapterIds,
        ...value.openedChapterIds,
        value.chapterId,
      },
      updatedAt: value.updatedAt,
    );
    state = state.copyWith(
      progress: {...state.progress, value.mangaId: normalized},
    );
    try {
      await _store.saveProgress(_uid, normalized);
    } catch (_) {
      // Keep reading uninterrupted when optional cloud sync is unavailable.
    }
  }

  Future<void> clearAll() async {
    await _store.clearSession(_uid);
    state = const UserLibraryState(loading: false);
  }
}
