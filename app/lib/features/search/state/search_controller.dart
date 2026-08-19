import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/catalog_repository.dart';
import '../../../core/models/manga.dart';
import '../data/metadata_provider.dart';

class SearchFilters {
  const SearchFilters({
    this.format = MangaBrowseFormat.all,
    this.status = MangaBrowseStatus.all,
    this.country = MangaBrowseCountry.all,
    this.genres = const <String>{},
    this.year,
    this.minimumRating,
    this.minimumChapters,
    this.sort = MangaBrowseSort.relevance,
  });

  final MangaBrowseFormat format;
  final MangaBrowseStatus status;
  final MangaBrowseCountry country;
  final Set<String> genres;
  final int? year;
  final int? minimumRating;
  final int? minimumChapters;
  final MangaBrowseSort sort;

  bool get hasActive => activeCount > 0;

  int get activeCount =>
      (format == MangaBrowseFormat.all ? 0 : 1) +
      (status == MangaBrowseStatus.all ? 0 : 1) +
      (country == MangaBrowseCountry.all ? 0 : 1) +
      (genres.isEmpty ? 0 : 1) +
      (year == null ? 0 : 1) +
      (minimumRating == null ? 0 : 1) +
      (minimumChapters == null ? 0 : 1) +
      (sort == MangaBrowseSort.relevance ? 0 : 1);

  SearchFilters copyWith({
    MangaBrowseFormat? format,
    MangaBrowseStatus? status,
    MangaBrowseCountry? country,
    Set<String>? genres,
    int? year,
    bool clearYear = false,
    int? minimumRating,
    bool clearMinimumRating = false,
    int? minimumChapters,
    bool clearMinimumChapters = false,
    MangaBrowseSort? sort,
  }) {
    return SearchFilters(
      format: format ?? this.format,
      status: status ?? this.status,
      country: country ?? this.country,
      genres: genres ?? this.genres,
      year: clearYear ? null : year ?? this.year,
      minimumRating: clearMinimumRating
          ? null
          : minimumRating ?? this.minimumRating,
      minimumChapters: clearMinimumChapters
          ? null
          : minimumChapters ?? this.minimumChapters,
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
  SearchController(this._repository, {required this.adultOnly})
    : super(const SearchState());

  final CatalogRepository _repository;
  final bool adultOnly;

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

    _timer = Timer(
      const Duration(milliseconds: 280),
      () => _run(value, generation, submitted: trimmed.length < 2),
    );
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
      state = state.copyWith(results: const <Manga>[], submitted: false);
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
      final result = await _repository.browse(
        MangaBrowseRequest(
          query: query,
          adultOnly: adultOnly,
          format: filters.format,
          status: filters.status,
          country: filters.country,
          genres: filters.genres,
          year: filters.year,
          minimumRating: filters.minimumRating,
          minimumChapters: filters.minimumChapters,
          sort: filters.sort,
        ),
      );

      if (generation != _generation) return;
      state = state.copyWith(
        results: result
            .where((manga) => manga.isAdult == adultOnly)
            .toList(growable: false),
        loading: false,
        submitted: submitted,
      );
    } catch (_) {
      if (generation == _generation) {
        state = state.copyWith(
          loading: false,
          error: 'Search is unavailable. Try again.',
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
