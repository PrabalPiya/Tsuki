import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/catalog_repository.dart';
import '../../../core/models/manga.dart';
import '../data/metadata_provider.dart';

class SearchFilters {
  const SearchFilters({
    this.genre,
    this.status = MangaBrowseStatus.all,
    this.sort = MangaBrowseSort.relevance,
  });

  final String? genre;
  final MangaBrowseStatus status;
  final MangaBrowseSort sort;

  bool get hasActive => activeCount > 0;

  int get activeCount =>
      ((genre == null || genre!.trim().isEmpty) ? 0 : 1) +
      (status == MangaBrowseStatus.all ? 0 : 1) +
      (sort == MangaBrowseSort.relevance ? 0 : 1);

  SearchFilters copyWith({
    String? genre,
    bool clearGenre = false,
    MangaBrowseStatus? status,
    MangaBrowseSort? sort,
  }) {
    return SearchFilters(
      genre: clearGenre ? null : genre ?? this.genre,
      status: status ?? this.status,
      sort: sort ?? this.sort,
    );
  }
}

class SearchState {
  const SearchState({
    this.query = '',
    this.results = const <Manga>[],
    this.loading = false,
    this.submitted = false,
    this.filters = const SearchFilters(),
    this.error,
  });

  final String query;
  final List<Manga> results;
  final bool loading;
  final bool submitted;
  final SearchFilters filters;
  final String? error;

  bool get hasBrowseRequest => query.trim().length >= 2 || filters.hasActive;

  SearchState copyWith({
    String? query,
    List<Manga>? results,
    bool? loading,
    bool? submitted,
    SearchFilters? filters,
    String? error,
    bool clearError = false,
  }) {
    return SearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      loading: loading ?? this.loading,
      submitted: submitted ?? this.submitted,
      filters: filters ?? this.filters,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class SearchController extends StateNotifier<SearchState> {
  SearchController(this._repository) : super(const SearchState());

  final CatalogRepository _repository;
  Timer? _timer;
  int _generation = 0;

  void updateQuery(String value) {
    state = state.copyWith(query: value, submitted: false, clearError: true);
    _timer?.cancel();
    final generation = ++_generation;
    final trimmed = value.trim();

    if (trimmed.length < 2 && !state.filters.hasActive) {
      state = state.copyWith(results: const <Manga>[], loading: false);
      return;
    }

    if (trimmed.length >= 2) {
      _timer = Timer(
        const Duration(milliseconds: 280),
        () => _run(value, generation, submitted: false),
      );
    }
  }

  Future<void> submit([String? value]) async {
    _timer?.cancel();
    final query = value ?? state.query;
    final generation = ++_generation;
    if (query.trim().length < 2 && !state.filters.hasActive) return;
    await _run(query, generation, submitted: true);
  }

  void updateFilters(SearchFilters filters) {
    state = state.copyWith(filters: filters, clearError: true);
  }

  Future<void> applyFilters() async {
    _timer?.cancel();
    final generation = ++_generation;
    if (state.query.trim().length < 2 && !state.filters.hasActive) {
      state = state.copyWith(
        results: const <Manga>[],
        loading: false,
        submitted: false,
      );
      return;
    }
    await _run(state.query, generation, submitted: true);
  }

  Future<void> clearFilters() async {
    state = state.copyWith(filters: const SearchFilters(), clearError: true);
    _timer?.cancel();
    final generation = ++_generation;
    if (state.query.trim().length >= 2) {
      await _run(state.query, generation, submitted: false);
    } else {
      state = state.copyWith(
        results: const <Manga>[],
        loading: false,
        submitted: false,
      );
    }
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

    try {
      final filters = state.filters;
      final genres = filters.genre == null || filters.genre!.trim().isEmpty
          ? const <String>{}
          : <String>{filters.genre!.trim()};

      final result = await _repository.browse(
        MangaBrowseRequest(
          query: query,
          adultOnly: false,
          status: filters.status,
          genres: genres,
          minimumChapters: null,
          sort: filters.sort,
        ),
      );

      if (generation != _generation) return;
      state = state.copyWith(
        results: result.where((manga) => !manga.isAdult).toList(growable: false),
        loading: false,
        submitted: submitted,
        clearError: true,
      );
    } catch (_) {
      if (generation == _generation) {
        state = state.copyWith(
          loading: false,
          error: 'Could not reach the manga catalogue. Try again.',
        );
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
