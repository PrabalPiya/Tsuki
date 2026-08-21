import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

/// AniList-backed catalogue metadata.
///
/// Search/browse intentionally uses a small, stable subset of AniList's manga
/// browse API. Keeping the request surface narrow makes Search reliable while
/// still supporting the four filters Tsuki exposes: genre, sort, status and
/// minimum chapters.
class AniListMetadataProvider
    implements MetadataProvider, BrowseMetadataProvider {
  AniListMetadataProvider({Dio? client, SynopsisService? synopsisService})
    : _client =
          client ?? createHttpClient(baseUrl: 'https://graphql.anilist.co'),
      _synopsis = synopsisService ?? const DeterministicSynopsisService();

  final Dio _client;
  final SynopsisService _synopsis;

  @override
  String get id => 'anilist';

  static const fields = r'''id idMal title { romaji english native } synonyms
    description(asHtml: false) status format countryOfOrigin startDate { year }
    averageScore popularity coverImage { extraLarge large } chapters volumes
    genres isAdult''';

  @override
  Future<List<Manga>> search(String query, {required bool includeAdult}) {
    return browse(
      MangaBrowseRequest(
        query: query,
        adultOnly: includeAdult,
        sort: MangaBrowseSort.relevance,
        perPage: 24,
      ),
    );
  }

  @override
  Future<List<Manga>> browse(MangaBrowseRequest request) async {
    const document = r'''query BrowseManga(
      $page: Int!,
      $perPage: Int!,
      $search: String,
      $isAdult: Boolean!,
      $status: MediaStatus,
      $genres: [String],
      $minChapters: Int,
      $sort: [MediaSort]!
    ) {
      Page(page: $page, perPage: $perPage) {
        media(
          type: MANGA,
          search: $search,
          isAdult: $isAdult,
          status: $status,
          genre_in: $genres,
          chapters_greater: $minChapters,
          sort: $sort
        ) {
          id idMal title { romaji english native } synonyms
          description(asHtml: false) status format countryOfOrigin
          startDate { year } averageScore popularity
          coverImage { extraLarge large } chapters volumes genres isAdult
        }
      }
    }''';

    final query = request.query.trim();
    final variables = <String, Object?>{
      'page': request.page,
      'perPage': request.perPage.clamp(1, 50),
      'search': query.length >= 2 ? query : null,
      'isAdult': request.adultOnly,
      'status': _statusVariable(request.status),
      'genres': request.genres.isEmpty ? null : request.genres.toList(),
      // AniList uses a strict "greater than" filter.
      'minChapters': request.minimumChapters == null
          ? null
          : (request.minimumChapters! - 1).clamp(0, 20000),
      'sort': _serverSort(request.sort, hasSearch: query.length >= 2),
    };

    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{'query': document, 'variables': variables},
    );

    final root = response.data?['data'];
    if (root is! Map) return const <Manga>[];
    final page = root['Page'];
    if (page is! Map) return const <Manga>[];

    final media = page['media'];
    if (media is! List) return const <Manga>[];

    var values = media
        .whereType<Map>()
        .map((raw) => _fromJson(Map<String, dynamic>.from(raw)))
        .where((manga) => manga.isAdult == request.adultOnly)
        .toList(growable: false);

    // AniList does not expose a stable chapter-count MediaSort in all schema
    // versions. Fetch with a safe catalogue sort and do this one sort locally.
    if (request.sort == MangaBrowseSort.chapters) {
      values = [...values]
        ..sort((a, b) {
          final chapters = b.metadataChapterCount.compareTo(
            a.metadataChapterCount,
          );
          if (chapters != 0) return chapters;
          return (b.popularity ?? 0).compareTo(a.popularity ?? 0);
        });
    }

    return values;
  }

  @override
  Future<Manga?> getById(String id) async {
    final value = int.tryParse(id.replaceFirst('anilist:', ''));
    if (value == null) return null;

    final document =
        '''query Manga(\$id: Int!) { Media(id: \$id, type: MANGA) { $fields } }''';
    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{
        'query': document,
        'variables': <String, Object?>{'id': value},
      },
    );
    final data = response.data?['data'];
    if (data is! Map) return null;
    final media = data['Media'];
    return media is Map ? _fromJson(Map<String, dynamic>.from(media)) : null;
  }

  Future<List<Manga>> browseTrending({bool adultOnly = false}) =>
      _browseRanking('TRENDING_DESC', adultOnly: adultOnly);

  Future<List<Manga>> browsePopular({bool adultOnly = false}) =>
      _browseRanking('POPULARITY_DESC', adultOnly: adultOnly);

  Future<List<Manga>> browsePopularThisSeason({bool adultOnly = false}) =>
      _browseRanking(
        'POPULARITY_DESC',
        adultOnly: adultOnly,
        season: _currentSeason(),
        seasonYear: DateTime.now().year,
      );

  Future<List<Manga>> browseTopRated({bool adultOnly = false}) =>
      _browseRanking('SCORE_DESC', adultOnly: adultOnly);

  Future<List<Manga>> _browseRanking(
    String sort, {
    required bool adultOnly,
    String? season,
    int? seasonYear,
  }) async {
    final seasonClause = season == null || seasonYear == null
        ? ''
        : 'season: $season, seasonYear: $seasonYear,';
    final document =
        '''query BrowseManga { Page(page: 1, perPage: 24) { media(type: MANGA, isAdult: $adultOnly, $seasonClause sort: $sort) { $fields } } }''';

    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{'query': document},
    );
    final data = response.data?['data'];
    if (data is! Map) return const <Manga>[];
    final page = data['Page'];
    if (page is! Map) return const <Manga>[];
    final media = page['media'];
    if (media is! List) return const <Manga>[];

    return media
        .whereType<Map>()
        .map((raw) => _fromJson(Map<String, dynamic>.from(raw)))
        .where((manga) => manga.isAdult == adultOnly)
        .toList(growable: false);
  }

  String? _statusVariable(MangaBrowseStatus value) => switch (value) {
    MangaBrowseStatus.all => null,
    MangaBrowseStatus.ongoing => 'RELEASING',
    MangaBrowseStatus.completed => 'FINISHED',
    MangaBrowseStatus.hiatus => 'HIATUS',
    MangaBrowseStatus.cancelled => 'CANCELLED',
  };

  List<String> _serverSort(MangaBrowseSort value, {required bool hasSearch}) {
    return switch (value) {
      MangaBrowseSort.relevance =>
        hasSearch
            ? const <String>['SEARCH_MATCH', 'POPULARITY_DESC']
            : const <String>['POPULARITY_DESC', 'SCORE_DESC'],
      MangaBrowseSort.popularity => const <String>[
        'POPULARITY_DESC',
        'SCORE_DESC',
      ],
      MangaBrowseSort.rating => const <String>['SCORE_DESC', 'POPULARITY_DESC'],
      MangaBrowseSort.trending => const <String>[
        'TRENDING_DESC',
        'POPULARITY_DESC',
      ],
      MangaBrowseSort.newest => const <String>[
        'START_DATE_DESC',
        'POPULARITY_DESC',
      ],
      MangaBrowseSort.title => const <String>['TITLE_ROMAJI'],
      // Chapter ordering is applied locally after a safe server sort.
      MangaBrowseSort.chapters => const <String>[
        'POPULARITY_DESC',
        'SCORE_DESC',
      ],
    };
  }

  String _currentSeason() {
    final month = DateTime.now().month;
    if (month >= 3 && month <= 5) return 'SPRING';
    if (month >= 6 && month <= 8) return 'SUMMER';
    if (month >= 9 && month <= 11) return 'FALL';
    return 'WINTER';
  }

  Manga _fromJson(Map<String, dynamic> json) {
    final title = json['title'] is Map
        ? Map<String, dynamic>.from(json['title'] as Map)
        : const <String, dynamic>{};
    final cover = json['coverImage'] is Map
        ? Map<String, dynamic>.from(json['coverImage'] as Map)
        : const <String, dynamic>{};
    final startDate = json['startDate'] is Map
        ? Map<String, dynamic>.from(json['startDate'] as Map)
        : const <String, dynamic>{};
    final score = json['averageScore'] as num?;
    final id = (json['id'] as num).toInt();

    return Manga(
      id: 'anilist:$id',
      anilistId: id,
      malId: (json['idMal'] as num?)?.toInt(),
      title:
          (title['english'] ?? title['romaji'] ?? title['native'] ?? 'Untitled')
              .toString(),
      aliases: <String>{
        ...title.values.whereType<String>(),
        ...(json['synonyms'] as List? ?? const <Object>[]).whereType<String>(),
      }.toList(growable: false),
      coverUrl: (cover['extraLarge'] ?? cover['large'] ?? '').toString(),
      synopsis: _synopsis.summarize(json['description']?.toString() ?? ''),
      status: _status(json['status']?.toString()),
      rating: score == null ? null : score.toDouble() / 10,
      chapterCount: (json['chapters'] as num?)?.toInt() ?? 0,
      isAdult: json['isAdult'] as bool? ?? false,
      format: _format(json['format']?.toString()),
      countryCode: json['countryOfOrigin']?.toString(),
      startYear: (startDate['year'] as num?)?.toInt(),
      volumeCount: (json['volumes'] as num?)?.toInt() ?? 0,
      genres: (json['genres'] as List? ?? const <Object>[])
          .whereType<String>()
          .toList(growable: false),
      popularity: (json['popularity'] as num?)?.toInt(),
    );
  }

  MangaStatus _status(String? value) => switch (value) {
    'RELEASING' => MangaStatus.ongoing,
    'FINISHED' => MangaStatus.completed,
    'HIATUS' => MangaStatus.hiatus,
    'CANCELLED' => MangaStatus.cancelled,
    'NOT_YET_RELEASED' => MangaStatus.notYetReleased,
    _ => MangaStatus.unknown,
  };

  MangaFormat _format(String? value) => switch (value) {
    'MANGA' => MangaFormat.manga,
    'ONE_SHOT' => MangaFormat.oneShot,
    'NOVEL' => MangaFormat.novel,
    _ => MangaFormat.unknown,
  };
}
