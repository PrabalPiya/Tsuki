import '../../../core/models/manga.dart';

enum MangaBrowseStatus { all, ongoing, completed, hiatus, cancelled }

enum MangaBrowseSort {
  relevance,
  popularity,
  rating,
  trending,
  newest,
  title,
  chapters,
}

/// Minimal browse request used by Tsuki Search.
///
/// Keep this intentionally small so the filter UI and metadata backend stay in
/// lockstep: genre, sort, status, and minimum chapters are the only exposed
/// filters. A blank [query] is valid when at least one filter/sort is active.
class MangaBrowseRequest {
  const MangaBrowseRequest({
    this.query = '',
    required this.adultOnly,
    this.status = MangaBrowseStatus.all,
    this.genres = const <String>{},
    this.minimumChapters,
    this.sort = MangaBrowseSort.relevance,
    this.page = 1,
    this.perPage = 36,
  });

  final String query;
  final bool adultOnly;
  final MangaBrowseStatus status;
  final Set<String> genres;
  final int? minimumChapters;
  final MangaBrowseSort sort;
  final int page;
  final int perPage;

  bool get hasFilters =>
      status != MangaBrowseStatus.all ||
      genres.isNotEmpty ||
      minimumChapters != null ||
      sort != MangaBrowseSort.relevance;
}

abstract interface class MetadataProvider {
  String get id;
  Future<List<Manga>> search(String query, {required bool includeAdult});
  Future<Manga?> getById(String id);
}

/// Optional richer metadata capability used by filter-only browsing.
///
/// Kept separate from [MetadataProvider] so lightweight test/demo providers do
/// not need to implement catalogue browsing.
abstract interface class BrowseMetadataProvider {
  Future<List<Manga>> browse(MangaBrowseRequest request);
}

abstract interface class SynopsisService {
  String summarize(String rawDescription);
}

class DeterministicSynopsisService implements SynopsisService {
  const DeterministicSynopsisService();

  @override
  String summarize(String rawDescription) {
    final plain = rawDescription
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'[_*~`>#]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (plain.isEmpty) return 'Synopsis unavailable.';

    final sentences = plain
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((value) => value.length > 20)
        .take(8)
        .toList(growable: false);
    final selected = sentences.isEmpty ? plain : sentences.join(' ');
    return selected.length <= 1000
        ? selected
        : '${selected.substring(0, 997).trimRight()}…';
  }
}
