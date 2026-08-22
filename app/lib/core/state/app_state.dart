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
  ({Set<String> ids, Map<String, Manga> manga})? _pendingBookmarks;
  Future<void>? _bookmarkWriter;
  final Map<String, ReadingProgress> _pendingProgress = {};
  Future<void>? _progressWriter;

  Future<void> _load() async {
    try {
      final value = await _store.load(_uid);
      if (!mounted) return;
      state = UserLibraryState(
        loading: false,
        bookmarks: value.bookmarks,
        bookmarkedManga: value.bookmarkedManga,
        progress: value.progress,
      );
    } catch (_) {
      if (mounted) state = const UserLibraryState(loading: false);
    }
  }

  Future<void> toggleBookmark(Manga manga) async {
    if (!manga.isFriendlyContent) return;
    final next = {...state.bookmarks};
    final metadata = {...state.bookmarkedManga};
    if (!next.add(manga.id)) {
      next.remove(manga.id);
      metadata.remove(manga.id);
    } else {
      metadata[manga.id] = manga;
    }
    state = state.copyWith(bookmarks: next, bookmarkedManga: metadata);
    await _queueBookmarkSave(next, metadata);
  }

  Future<void> restoreBookmark(Manga manga) async {
    if (!manga.isFriendlyContent) return;
    final next = {...state.bookmarks, manga.id};
    final metadata = {...state.bookmarkedManga, manga.id: manga};
    state = state.copyWith(bookmarks: next, bookmarkedManga: metadata);
    await _queueBookmarkSave(next, metadata);
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
    _pendingProgress[value.mangaId] = normalized;
    await (_progressWriter ??= _flushProgress());
  }

  Future<void> clearAll() async {
    _pendingBookmarks = null;
    _pendingProgress.clear();
    await Future.wait([?_bookmarkWriter, ?_progressWriter]);
    await _store.clearSession(_uid);
    if (mounted) state = const UserLibraryState(loading: false);
  }

  Future<void> _queueBookmarkSave(Set<String> ids, Map<String, Manga> manga) {
    _pendingBookmarks = (
      ids: Set<String>.unmodifiable(ids),
      manga: Map<String, Manga>.unmodifiable(manga),
    );
    return _bookmarkWriter ??= _flushBookmarks();
  }

  Future<void> _flushBookmarks() async {
    try {
      while (_pendingBookmarks != null) {
        final next = _pendingBookmarks!;
        _pendingBookmarks = null;
        try {
          await _store.saveBookmarks(_uid, next.ids, next.manga);
        } catch (_) {
          // Optimistic UI remains usable while optional cloud sync recovers.
        }
      }
    } finally {
      _bookmarkWriter = null;
    }
  }

  Future<void> _flushProgress() async {
    try {
      while (_pendingProgress.isNotEmpty) {
        final values = _pendingProgress.values.toList(growable: false);
        _pendingProgress.clear();
        for (final value in values) {
          try {
            await _store.saveProgress(_uid, value);
          } catch (_) {
            // Reading remains uninterrupted while persistence is unavailable.
          }
        }
      }
    } finally {
      _progressWriter = null;
    }
  }
}
