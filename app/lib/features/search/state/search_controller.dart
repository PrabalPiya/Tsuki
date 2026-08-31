import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/data/catalog_repository.dart';
import '../../../core/identity/manga_identity_resolver.dart';
import '../../../core/models/manga.dart';
import '../../../core/storage/canonical_alias_index.dart';
import '../../../core/storage/manga_metadata_cache.dart';

class SearchState {
  const SearchState({
    this.query = '',
    this.results = const <Manga>[],
    this.loading = false,
    this.submitted = false,
    this.error,
  });

  final String query;
  final List<Manga> results;
  final bool loading;
  final bool submitted;
  final String? error;

  bool get hasBrowseRequest => query.trim().isNotEmpty;

  SearchState copyWith({
    String? query,
    List<Manga>? results,
    bool? loading,
    bool? submitted,
    String? error,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      loading: loading ?? this.loading,
      submitted: submitted ?? this.submitted,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SearchController extends StateNotifier<SearchState> {
  SearchController(
    this._repository,
    this._cache, [
    CanonicalAliasIndex? aliases,
  ]) : _aliases = aliases ?? CanonicalAliasIndex(),
       super(const SearchState()) {
    unawaited(_cache.warmSearchIndex());
  }

  final CatalogRepository _repository;
  final MangaMetadataCache _cache;
  final CanonicalAliasIndex _aliases;
  final MangaIdentityResolver _identityResolver = const MangaIdentityResolver();
  Timer? _remoteTimer;
  CancelToken? _remoteCancellation;
  int _generation = 0;
  // All configured metadata providers participate in autocomplete.
  // Wait for a deliberate typing pause so a six-letter query does not launch
  // six complete provider sweeps before the user finishes typing it.
  static const _remoteSearchDelay = Duration(milliseconds: 350);
  static const _suggestionLimit = 50;
  static const _resultLimit = 50;

  void reset() {
    _remoteTimer?.cancel();
    _cancelRemoteSearch();
    _generation++;
    state = const SearchState();
  }

  void updateQuery(String value) {
    _remoteTimer?.cancel();
    _cancelRemoteSearch();
    final generation = ++_generation;
    final trimmed = value.trim();

    if (trimmed.isEmpty || !_repository.isFriendlySearchQuery(trimmed)) {
      state = SearchState(query: value);
      return;
    }

    state = SearchState(
      query: value,
      // Results belong to the previous query until the local index finishes.
      // Clearing them prevents a fast tap from opening the wrong manga.
      loading: true,
    );
    unawaited(_showLocalResults(value, generation, submitted: false));

    if (trimmed.length >= 2) {
      _remoteTimer = Timer(
        _remoteSearchDelay,
        () => _mergeRemoteResults(value, generation, submitted: false),
      );
    }
  }

  Future<void> submit([String? value]) async {
    _remoteTimer?.cancel();
    _cancelRemoteSearch();
    final query = value ?? state.query;
    final generation = ++_generation;
    final trimmed = query.trim();
    if (trimmed.isEmpty || !_repository.isFriendlySearchQuery(trimmed)) {
      state = SearchState(query: query, submitted: true);
      return;
    }

    state = SearchState(
      query: query,
      results: state.results,
      loading: true,
      submitted: true,
    );
    await _showLocalResults(query, generation, submitted: true);
    if (generation != _generation) return;
    await _mergeRemoteResults(query, generation, submitted: true);
  }

  Future<void> _showLocalResults(
    String query,
    int generation, {
    required bool submitted,
  }) async {
    try {
      final limit = submitted ? _resultLimit : _suggestionLimit;
      final local = await Future.wait<List<Manga>>([
        _cache.searchIndex(query, limit: limit),
        _cache.loadSearch(query).then((values) => values ?? const <Manga>[]),
      ]);
      if (generation != _generation) return;
      final result = _dedupeLocal(local.expand((items) => items), limit);
      state = state.copyWith(
        results: _rememberFriendly(result),
        loading: submitted || (result.isEmpty && query.trim().length >= 2),
        submitted: submitted,
        clearError: true,
      );
    } catch (_) {
      if (generation == _generation) {
        final remoteWillRun = query.trim().length >= 2;
        state = state.copyWith(
          results: const <Manga>[],
          loading: remoteWillRun,
          error: remoteWillRun
              ? null
              : 'Search could not be completed. Please try again.',
          clearError: remoteWillRun,
        );
      }
    }
  }

  List<Manga> _dedupeLocal(Iterable<Manga> values, int limit) {
    final results = <Manga>[];
    for (final raw in values) {
      if (!_repository.isFriendly(raw) ||
          !_repository.isEnabledMetadataResult(raw)) {
        continue;
      }
      final manga = _repository.canonicalizeForLibrary(raw);
      final match = results.indexWhere(
        (current) => _identityResolver.compare(current, manga).canMerge,
      );
      if (match < 0) {
        if (results.length < limit) results.add(manga);
      } else {
        final existing = results[match];
        results[match] = _identityResolver
            .merge(existing, manga)
            .copyWith(id: existing.id);
      }
    }
    return results;
  }

  Future<void> _mergeRemoteResults(
    String query,
    int generation, {
    required bool submitted,
  }) async {
    final cancellation = CancelToken();
    _remoteCancellation = cancellation;
    try {
      var emitted = false;
      var finalResults = state.results;
      await for (final values in _repository.searchMetadataProgressive(
        query,
        cancelToken: cancellation,
      )) {
        if (generation != _generation) return;
        emitted = true;
        final merged = _mergeResults(
          state.results,
          _rememberFriendly(values),
          limit: submitted ? _resultLimit : _suggestionLimit,
        );
        for (final manga in merged) {
          _repository.remember(manga);
          unawaited(_aliases.learn(manga).catchError((_) {}));
        }
        finalResults = merged;
        state = state.copyWith(
          results: merged,
          loading: true,
          submitted: submitted,
          clearError: true,
        );
      }
      if (generation != _generation) return;
      // Persist only the complete provider merge. Saving every progressive
      // batch can race and leave a smaller, older batch in the cache.
      if (finalResults.isNotEmpty) {
        try {
          await _cache.saveSearch(query, finalResults);
        } catch (_) {
          // Search remains usable when its opportunistic cache write fails.
        }
      }
      if (generation != _generation) return;
      state = state.copyWith(
        loading: false,
        submitted: submitted,
        error: !emitted && state.results.isEmpty
            ? 'More manga could not be loaded. Try again.'
            : null,
        clearError: emitted || state.results.isNotEmpty,
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) return;
      if (generation != _generation) return;
      state = state.copyWith(
        loading: false,
        error: state.results.isEmpty
            ? 'More manga could not be loaded. Try again.'
            : null,
        clearError: state.results.isNotEmpty,
      );
    } catch (_) {
      if (generation != _generation) return;
      state = state.copyWith(
        loading: false,
        error: state.results.isEmpty
            ? 'More manga could not be loaded. Try again.'
            : null,
        clearError: state.results.isNotEmpty,
      );
    } finally {
      if (identical(_remoteCancellation, cancellation)) {
        _remoteCancellation = null;
      }
    }
  }

  void _cancelRemoteSearch() {
    final active = _remoteCancellation;
    if (active != null && !active.isCancelled) {
      active.cancel('Search query changed.');
    }
    _remoteCancellation = null;
  }

  List<Manga> _mergeResults(
    List<Manga> local,
    List<Manga> remote, {
    required int limit,
  }) {
    final merged = <Manga>[];

    final localById = {for (final manga in local) manga.id: manga};

    // AniList is already relevance-ranked. Preserve a known local chapter
    // total when AniList reports zero/unknown for an ongoing title.
    for (final raw in <Manga>[...remote, ...local]) {
      final localMatch = localById[raw.id];
      final manga =
          raw.metadataChapterCount <= 0 &&
              (localMatch?.metadataChapterCount ?? 0) > 0
          ? raw.copyWith(chapterCount: localMatch!.metadataChapterCount)
          : raw;
      final match = merged.indexWhere(
        (current) => _identityResolver.compare(current, manga).canMerge,
      );
      if (match < 0) {
        if (merged.length < limit) merged.add(manga);
      } else {
        merged[match] = _identityResolver.merge(merged[match], manga);
      }
    }
    return merged;
  }

  List<Manga> _rememberFriendly(List<Manga> values) {
    final safe = values
        .where(_repository.isFriendly)
        .where(_repository.isEnabledMetadataResult)
        .map(_repository.canonicalizeForLibrary)
        .toList(growable: false);
    for (final manga in safe) {
      _repository.remember(manga);
    }
    return safe;
  }

  @override
  void dispose() {
    _remoteTimer?.cancel();
    _cancelRemoteSearch();
    super.dispose();
  }
}
