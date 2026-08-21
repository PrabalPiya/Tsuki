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

  bool get hasBrowseRequest => query.trim().length >= 2;

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
  SearchController(this._repository, this._cache) : super(const SearchState());

  final CatalogRepository _repository;
  final MangaMetadataCache _cache;
  Timer? _timer;
  int _generation = 0;

  void reset() {
    _timer?.cancel();
    _generation++;
    state = const SearchState();
  }

  void updateQuery(String value) {
    state = state.copyWith(query: value, submitted: false, clearError: true);
    _timer?.cancel();
    final generation = ++_generation;
    final trimmed = value.trim();

    if (trimmed.length < 2 || !_repository.isFriendlySearchQuery(trimmed)) {
      state = state.copyWith(results: const <Manga>[], loading: false);
      return;
    }

    if (trimmed.length >= 2) {
      unawaited(_showCached(value, generation, submitted: false));
      _timer = Timer(
        const Duration(milliseconds: 120),
        () => _run(value, generation, submitted: false),
      );
    }
  }

  Future<void> submit([String? value]) async {
    _timer?.cancel();
    final query = value ?? state.query;
    final generation = ++_generation;
    final trimmed = query.trim();
    if (trimmed.length < 2 || !_repository.isFriendlySearchQuery(trimmed)) {
      state = state.copyWith(results: const <Manga>[], loading: false);
      return;
    }
    await _run(query, generation, submitted: true);
  }

  Future<void> _run(
    String query,
    int generation, {
    required bool submitted,
  }) async {
    state = state.copyWith(
      loading: true,
      submitted: submitted,
      clearError: true,
    );

    await _showCached(query, generation, submitted: submitted);

    try {
      final result = await _repository.search(query);

      if (generation != _generation) return;
      final safe = result.where(_repository.isFriendly).toList(growable: false);
      unawaited(_cache.saveSearch(query, safe));
      state = state.copyWith(
        results: safe,
        loading: false,
        submitted: submitted,
        clearError: true,
      );
    } catch (_) {
      if (generation == _generation) {
        if (state.results.isNotEmpty) {
          state = state.copyWith(loading: false, clearError: true);
          return;
        }

        state = state.copyWith(
          loading: false,
          error: 'Could not reach the manga catalogue. Try again.',
        );
      }
    }
  }

  Future<void> _showCached(
    String query,
    int generation, {
    required bool submitted,
  }) async {
    final indexed = await _cache.searchIndex(query);
    if (indexed.isNotEmpty && generation == _generation) {
      for (final manga in indexed) {
        _repository.remember(manga);
      }
      state = state.copyWith(
        results: indexed.where(_repository.isFriendly).toList(growable: false),
        loading: true,
        submitted: submitted,
        clearError: true,
      );
    }

    final cached = await _cache.loadSearch(query);
    if (cached != null && cached.isNotEmpty && generation == _generation) {
      for (final manga in cached) {
        _repository.remember(manga);
      }
      state = state.copyWith(
        results: cached.where(_repository.isFriendly).toList(growable: false),
        loading: true,
        submitted: submitted,
        clearError: true,
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
