import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';

import '../identity/manga_identity_resolver.dart';
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
  final MangaIdentityResolver _identityResolver = const MangaIdentityResolver();
  ({Set<String> ids, Map<String, Manga> manga})? _pendingBookmarks;
  Future<void>? _bookmarkWriter;
  final Map<String, ReadingProgress> _pendingProgress = {};
  Future<void>? _progressWriter;
  Timer? _bookmarkRetryTimer;
  Timer? _progressRetryTimer;
  int _bookmarkFailures = 0;
  int _progressFailures = 0;

  UserLibraryState get currentState => state;

  Future<void> _load() async {
    try {
      final value = await _store.load(_uid);
      if (!mounted) return;
      final normalized = _normalizeLibrary(value);
      state = UserLibraryState(
        loading: false,
        bookmarks: normalized.bookmarks,
        bookmarkedManga: normalized.manga,
        progress: normalized.progress,
      );
      if (normalized.changed) {
        await _queueBookmarkSave(normalized.bookmarks, normalized.manga);
        for (final progress in normalized.progress.values) {
          _pendingProgress[progress.mangaId] = progress;
        }
        await (_progressWriter ??= _flushProgress());
      }
    } catch (_) {
      if (mounted) state = const UserLibraryState(loading: false);
    }
  }

  ({
    Set<String> bookmarks,
    Map<String, Manga> manga,
    Map<String, ReadingProgress> progress,
    bool changed,
  })
  _normalizeLibrary(UserSnapshot snapshot) {
    final manga = <String, Manga>{};
    final remappedIds = <String, String>{};
    var changed = false;
    for (final id in snapshot.bookmarks) {
      final incoming = snapshot.bookmarkedManga[id];
      if (incoming == null || !incoming.isFriendlyContent) continue;
      final existing = manga.values
          .where(
            (candidate) =>
                _identityResolver.compare(candidate, incoming).canMerge,
          )
          .firstOrNull;
      if (existing == null) {
        manga[id] = incoming.copyWith(id: id);
        remappedIds[id] = id;
        continue;
      }
      changed = true;
      remappedIds[id] = existing.id;
      manga[existing.id] = _identityResolver
          .merge(existing, incoming)
          .copyWith(id: existing.id);
    }

    final progress = <String, ReadingProgress>{};
    for (final entry in snapshot.progress.entries) {
      final canonicalId = remappedIds[entry.key] ?? entry.key;
      final incoming = _withMangaId(entry.value, canonicalId);
      final previous = progress[canonicalId];
      if (previous == null || _preferProgress(incoming, previous)) {
        progress[canonicalId] = incoming;
      }
      if (canonicalId != entry.key) changed = true;
    }
    final bookmarks = manga.keys.toSet();
    if (bookmarks.length != snapshot.bookmarks.length) changed = true;
    return (
      bookmarks: bookmarks,
      manga: manga,
      progress: progress,
      changed: changed,
    );
  }

  bool _preferProgress(ReadingProgress incoming, ReadingProgress previous) {
    final incomingNumber =
        incoming.normalizedChapterNumber ??
        _numberFromChapterId(incoming.chapterId);
    final previousNumber =
        previous.normalizedChapterNumber ??
        _numberFromChapterId(previous.chapterId);
    if (incomingNumber != null && previousNumber != null) {
      if (incomingNumber != previousNumber) {
        return incomingNumber > previousNumber;
      }
    } else if (incomingNumber != null) {
      return true;
    } else if (previousNumber != null) {
      return false;
    }
    return incoming.updatedAt.isAfter(previous.updatedAt);
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

  Future<void> removeBookmarks(Iterable<String> mangaIds) async {
    final removedIds = mangaIds.toSet();
    if (removedIds.isEmpty ||
        !removedIds.any((id) => state.bookmarks.contains(id))) {
      return;
    }

    final next = {...state.bookmarks}..removeAll(removedIds);
    final metadata = {...state.bookmarkedManga}
      ..removeWhere((id, _) => removedIds.contains(id));
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
      rawChapter: value.rawChapter ?? previous?.rawChapter,
      normalizedChapterNumber:
          value.normalizedChapterNumber ?? previous?.normalizedChapterNumber,
      updatedAt: value.updatedAt,
    );
    state = state.copyWith(
      progress: {...state.progress, value.mangaId: normalized},
    );
    _pendingProgress[value.mangaId] = normalized;
    await (_progressWriter ??= _flushProgress());
  }

  Future<void> importBatch(
    Map<String, Manga> manga,
    Map<String, ReadingProgress> progress,
  ) async {
    final safeManga = <String, Manga>{};
    final remappedIds = <String, String>{};
    for (final entry in manga.entries) {
      final incoming = entry.value;
      if (!incoming.isFriendlyContent) continue;
      final existing =
          <Manga>[...state.bookmarkedManga.values, ...safeManga.values]
              .where(
                (candidate) =>
                    _identityResolver.compare(candidate, incoming).canMerge,
              )
              .firstOrNull;
      final canonicalId = existing?.id ?? entry.key;
      final canonical = existing == null
          ? incoming.copyWith(id: canonicalId)
          : _identityResolver
                .merge(existing, incoming)
                .copyWith(id: canonicalId);
      safeManga[canonicalId] = canonical;
      remappedIds[entry.key] = canonicalId;
    }
    final bookmarks = {...state.bookmarks, ...safeManga.keys};
    final metadata = {...state.bookmarkedManga, ...safeManga};
    final mergedProgress = {...state.progress};
    final acceptedProgress = <String, ReadingProgress>{};
    for (final entry in progress.entries) {
      final canonicalId = remappedIds[entry.key] ?? entry.key;
      final previous = mergedProgress[canonicalId];
      final incoming = _withMangaId(entry.value, canonicalId);
      final previousNumber = previous == null
          ? null
          : previous.normalizedChapterNumber ??
                _numberFromChapterId(previous.chapterId);
      final incomingNumber = incoming.normalizedChapterNumber;
      if (previous == null ||
          (incomingNumber != null &&
              (previousNumber == null || incomingNumber > previousNumber))) {
        mergedProgress[canonicalId] = incoming;
        acceptedProgress[canonicalId] = incoming;
      }
    }
    state = state.copyWith(
      bookmarks: bookmarks,
      bookmarkedManga: metadata,
      progress: mergedProgress,
    );

    if (_store is BatchUserStore) {
      await (_store as BatchUserStore).saveLibraryBatch(
        _uid,
        bookmarks,
        metadata,
        acceptedProgress,
      );
      return;
    }
    await _queueBookmarkSave(bookmarks, metadata);
    for (final value in acceptedProgress.values) {
      _pendingProgress[value.mangaId] = value;
    }
    await (_progressWriter ??= _flushProgress());
  }

  double? _numberFromChapterId(String chapterId) {
    final match = RegExp(r'(?:^|:)number:([0-9]+(?:\.[0-9]+)?)$')
        .firstMatch(chapterId);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  ReadingProgress _withMangaId(ReadingProgress value, String mangaId) =>
      value.mangaId == mangaId
      ? value
      : ReadingProgress(
          mangaId: mangaId,
          chapterId: value.chapterId,
          pageIndex: value.pageIndex,
          relativeOffset: value.relativeOffset,
          chapterProgress: value.chapterProgress,
          openedChapterIds: value.openedChapterIds,
          rawChapter: value.rawChapter,
          normalizedChapterNumber: value.normalizedChapterNumber,
          updatedAt: value.updatedAt,
        );

  Future<void> clearAll() async {
    _bookmarkRetryTimer?.cancel();
    _progressRetryTimer?.cancel();
    _pendingBookmarks = null;
    _pendingProgress.clear();
    await Future.wait([?_bookmarkWriter, ?_progressWriter]);
    _bookmarkRetryTimer?.cancel();
    _progressRetryTimer?.cancel();
    _pendingBookmarks = null;
    _pendingProgress.clear();
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
          _bookmarkFailures = 0;
        } catch (_) {
          // Retain the newest unsaved snapshot and retry in the background.
          // A newer queued value always wins over this failed snapshot.
          _pendingBookmarks ??= next;
          _bookmarkFailures++;
          _scheduleBookmarkRetry();
          break;
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
        var failed = false;
        for (final value in values) {
          try {
            await _store.saveProgress(_uid, value);
            _progressFailures = 0;
          } catch (_) {
            // Do not overwrite newer progress queued while this write was in
            // flight. The retained value is retried without blocking reading.
            _pendingProgress.putIfAbsent(value.mangaId, () => value);
            _progressFailures++;
            failed = true;
          }
        }
        if (failed) {
          _scheduleProgressRetry();
          break;
        }
      }
    } finally {
      _progressWriter = null;
    }
  }

  void _scheduleBookmarkRetry() {
    _bookmarkRetryTimer?.cancel();
    _bookmarkRetryTimer = Timer(_retryDelay(_bookmarkFailures), () {
      if (!mounted || _pendingBookmarks == null) return;
      unawaited(_bookmarkWriter ??= _flushBookmarks());
    });
  }

  void _scheduleProgressRetry() {
    _progressRetryTimer?.cancel();
    _progressRetryTimer = Timer(_retryDelay(_progressFailures), () {
      if (!mounted || _pendingProgress.isEmpty) return;
      unawaited(_progressWriter ??= _flushProgress());
    });
  }

  Duration _retryDelay(int failures) {
    final seconds = 1 << failures.clamp(0, 5);
    return Duration(seconds: seconds.clamp(2, 30));
  }

  @override
  void dispose() {
    _bookmarkRetryTimer?.cancel();
    _progressRetryTimer?.cancel();
    super.dispose();
  }
}
