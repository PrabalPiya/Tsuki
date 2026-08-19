import '../../../core/models/manga.dart';

enum MangaBrowseFormat { all, manga, oneShot, novel }

enum MangaBrowseStatus {
  all,
  ongoing,
  completed,
  hiatus,
  cancelled,
  notYetReleased,
}

enum MangaBrowseCountry { all, japan, southKorea, china, taiwan }

enum MangaBrowseSort {
  relevance,
  popularity,
  rating,
  trending,
  newest,
  title,
  chapters,
}

class MangaBrowseRequest {
  const MangaBrowseRequest({
    this.query = '',
    required this.adultOnly,
    this.format = MangaBrowseFormat.all,
    this.status = MangaBrowseStatus.all,
    this.country = MangaBrowseCountry.all,
    this.genres = const <String>{},
    this.year,
    this.minimumRating,
    this.minimumChapters,
    this.sort = MangaBrowseSort.relevance,
    this.page = 1,
    this.perPage = 36,
  });

  final String query;
  final bool adultOnly;
  final MangaBrowseFormat format;
  final MangaBrowseStatus status;
  final MangaBrowseCountry country;
  final Set<String> genres;
  final int? year;
  final int? minimumRating;
  final int? minimumChapters;
  final MangaBrowseSort sort;
  final int page;
  final int perPage;

  bool get hasFilters =>
      format != MangaBrowseFormat.all ||
      status != MangaBrowseStatus.all ||
      country != MangaBrowseCountry.all ||
      genres.isNotEmpty ||
      year != null ||
      minimumRating != null ||
      minimumChapters != null ||
      sort != MangaBrowseSort.relevance;
}

abstract interface class MetadataProvider {
  String get id;
  Future<List<Manga>> search(String query, {required bool includeAdult});
  Future<Manga?> getById(String id);
}

/// Optional richer metadata capability used by Search filters.
///
/// Keeping this separate from [MetadataProvider] preserves compatibility with
/// simple/test metadata implementations that only support title search.
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
        .where((v) => v.length > 20)
        .take(8)
        .toList();
    final selected = sentences.isEmpty ? plain : sentences.join(' ');
    return selected.length <= 1000
        ? selected
        : '${selected.substring(0, 997).trimRight()}…';
  }
}
