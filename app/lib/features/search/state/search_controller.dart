import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/catalog_repository.dart';
import '../../../core/models/manga.dart';
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
  SearchController(this._repository, this._cache) : super(const SearchState()) {
    unawaited(_cache.warmSearchIndex());
  }

  final CatalogRepository _repository;
  final MangaMetadataCache _cache;
  Timer? _remoteTimer;
  int _generation = 0;
  static const _remoteSearchDelay = Duration(milliseconds: 300);
  static const _suggestionLimit = 50;
  static const _resultLimit = 50;

  void reset() {
    _remoteTimer?.cancel();
    _generation++;
    state = const SearchState();
  }

  void updateQuery(String value) {
    _remoteTimer?.cancel();
    final generation = ++_generation;
    final trimmed = value.trim();

    if (trimmed.isEmpty || !_repository.isFriendlySearchQuery(trimmed)) {
      state = SearchState(query: value);
      return;
    }

    state = SearchState(
      query: value,
      results: state.results,
      loading: state.results.isEmpty,
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
        state = state.copyWith(
          results: const <Manga>[],
          loading: false,
          error: 'The local manga catalogue could not be searched.',
        );
      }
    }
  }

  List<Manga> _dedupeLocal(Iterable<Manga> values, int limit) {
    final seen = <String>{};
    final results = <Manga>[];
    for (final manga in values) {
      if (!seen.add(manga.id)) continue;
      results.add(manga);
      if (results.length == limit) break;
    }
    return results;
  }

  Future<void> _mergeRemoteResults(
    String query,
    int generation, {
    required bool submitted,
  }) async {
    try {
      final values = await _repository.searchMetadataOnly(query);
      if (generation != _generation) return;

      final remote = _rememberFriendly(values);
      final merged = _mergeResults(
        state.results,
        remote,
        limit: submitted ? _resultLimit : _suggestionLimit,
      );
      for (final manga in merged) {
        _repository.remember(manga);
      }
      unawaited(_cache.saveSearch(query, merged).catchError((_) {}));
      state = state.copyWith(
        results: merged,
        loading: false,
        submitted: submitted,
        clearError: true,
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
    }
  }

  List<Manga> _mergeResults(
    List<Manga> local,
    List<Manga> remote, {
    required int limit,
  }) {
    final seenIds = <String>{};
    final seenTitles = <String>{};
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
      final title = manga.title.trim().toLowerCase();
      if (!seenIds.add(manga.id) || !seenTitles.add(title)) continue;
      merged.add(manga);
      if (merged.length == limit) break;
    }
    return merged;
  }

  List<Manga> _rememberFriendly(List<Manga> values) {
    final safe = values.where(_repository.isFriendly).toList(growable: false);
    for (final manga in safe) {
      _repository.remember(manga);
    }
    return safe;
  }

  @override
  void dispose() {
    _remoteTimer?.cancel();
    super.dispose();
  }
}
