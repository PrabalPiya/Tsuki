import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/data/catalog_repository.dart';
import '../../../core/models/manga.dart';

class SearchState {
  const SearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
    this.submitted = false,
    this.error,
  });
  final String query;
  final List<Manga> results;
  final bool loading, submitted;
  final String? error;
  SearchState copyWith({
    String? query,
    List<Manga>? results,
    bool? loading,
    bool? submitted,
    String? error,
    bool clearError = false,
  }) => SearchState(
    query: query ?? this.query,
    results: results ?? this.results,
    loading: loading ?? this.loading,
    submitted: submitted ?? this.submitted,
    error: clearError ? null : error ?? this.error,
  );
}

class SearchController extends StateNotifier<SearchState> {
  SearchController(this._repository, {required bool Function() includeAdult})
    : _includeAdult = includeAdult,
      super(const SearchState());
  final CatalogRepository _repository;
  final bool Function() _includeAdult;
  Timer? _timer;
  int _generation = 0;
  void updateQuery(String value) {
    state = state.copyWith(query: value, submitted: false, clearError: true);
    _timer?.cancel();
    final generation = ++_generation;
    if (value.trim().length < 2) {
      state = state.copyWith(results: const [], loading: false);
      return;
    }
    _timer = Timer(
      const Duration(milliseconds: 300),
      () => _run(value, generation, false),
    );
  }

  Future<void> submit([String? value]) async {
    _timer?.cancel();
    final query = value ?? state.query;
    final generation = ++_generation;
    if (query.trim().length < 2) return;
    await _run(query, generation, true);
  }

  Future<void> _run(String query, int generation, bool submitted) async {
    state = state.copyWith(
      loading: true,
      submitted: submitted,
      clearError: true,
    );
    try {
      final result = await _repository.search(
        query,
        includeAdult: _includeAdult(),
      );
      if (generation == _generation) {
        state = state.copyWith(
          results: result,
          loading: false,
          submitted: submitted,
        );
      }
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
