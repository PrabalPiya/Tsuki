import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

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
    final document =
        '''query BrowseManga(
      \$page: Int!,
      \$perPage: Int!,
      \$search: String,
      \$isAdult: Boolean!,
      \$format: MediaFormat,
      \$status: MediaStatus,
      \$country: CountryCode,
      \$year: String,
      \$genres: [String],
      \$minScore: Int,
      \$minChapters: Int,
      \$sort: [MediaSort]!
    ) {
      Page(page: \$page, perPage: \$perPage) {
        media(
          type: MANGA,
          search: \$search,
          isAdult: \$isAdult,
          format: \$format,
          status: \$status,
          countryOfOrigin: \$country,
          startDate_like: \$year,
          genre_in: \$genres,
          averageScore_greater: \$minScore,
          chapters_greater: \$minChapters,
          sort: \$sort
        ) { $fields }
      }
    }''';

    final trimmedQuery = request.query.trim();
    final variables = <String, Object?>{
      'page': request.page,
      'perPage': request.perPage.clamp(1, 50),
      'search': trimmedQuery.length >= 2 ? trimmedQuery : null,
      'isAdult': request.adultOnly,
      'format': _formatVariable(request.format),
      'status': _statusVariable(request.status),
      'country': _countryVariable(request.country),
      'year': request.year == null ? null : '${request.year}%',
      'genres': request.genres.isEmpty ? null : request.genres.toList(),
      'minScore': request.minimumRating == null
          ? null
          : (request.minimumRating! * 10 - 1).clamp(0, 100),
      'minChapters': request.minimumChapters == null
          ? null
          : (request.minimumChapters! - 1).clamp(0, 20000),
      'sort': _sortVariable(request.sort, hasSearch: trimmedQuery.length >= 2),
    };

    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{'query': document, 'variables': variables},
    );

    final page =
        (response.data?['data'] as Map<String, dynamic>?)?['Page']
            as Map<String, dynamic>?;
    return (page?['media'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((raw) => _fromJson(Map<String, dynamic>.from(raw)))
        .where((manga) => manga.isAdult == request.adultOnly)
        .toList(growable: false);
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
    final media =
        (response.data?['data'] as Map<String, dynamic>?)?['Media']
            as Map<String, dynamic>?;
    return media == null ? null : _fromJson(media);
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
        '''query BrowseManga {
      Page(page: 1, perPage: 24) {
        media(type: MANGA, isAdult: $adultOnly, $seasonClause sort: $sort) {
          $fields
        }
      }
    }''';
    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{'query': document},
    );
    final page =
        (response.data?['data'] as Map<String, dynamic>?)?['Page']
            as Map<String, dynamic>?;
    return (page?['media'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((raw) => _fromJson(Map<String, dynamic>.from(raw)))
        .where((manga) => manga.isAdult == adultOnly)
        .toList(growable: false);
  }

  String? _formatVariable(MangaBrowseFormat value) => switch (value) {
    MangaBrowseFormat.all => null,
    MangaBrowseFormat.manga => 'MANGA',
    MangaBrowseFormat.oneShot => 'ONE_SHOT',
    MangaBrowseFormat.novel => 'NOVEL',
  };

  String? _statusVariable(MangaBrowseStatus value) => switch (value) {
    MangaBrowseStatus.all => null,
    MangaBrowseStatus.ongoing => 'RELEASING',
    MangaBrowseStatus.completed => 'FINISHED',
    MangaBrowseStatus.hiatus => 'HIATUS',
    MangaBrowseStatus.cancelled => 'CANCELLED',
    MangaBrowseStatus.notYetReleased => 'NOT_YET_RELEASED',
  };

  String? _countryVariable(MangaBrowseCountry value) => switch (value) {
    MangaBrowseCountry.all => null,
    MangaBrowseCountry.japan => 'JP',
    MangaBrowseCountry.southKorea => 'KR',
    MangaBrowseCountry.china => 'CN',
    MangaBrowseCountry.taiwan => 'TW',
  };

  List<String> _sortVariable(MangaBrowseSort value, {required bool hasSearch}) {
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
      MangaBrowseSort.chapters => const <String>[
        'CHAPTERS_DESC',
        'POPULARITY_DESC',
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
    final title = json['title'] as Map<String, dynamic>? ?? const {};
    final cover = json['coverImage'] as Map<String, dynamic>? ?? const {};
    final startDate = json['startDate'] as Map<String, dynamic>? ?? const {};
    final score = json['averageScore'] as num?;
    final id = json['id'] as int;

    return Manga(
      id: 'anilist:$id',
      anilistId: id,
      malId: json['idMal'] as int?,
      title:
          (title['english'] ?? title['romaji'] ?? title['native'] ?? 'Untitled')
              as String,
      aliases: <String>{
        ...title.values.whereType<String>(),
        ...(json['synonyms'] as List? ?? const <Object>[]).whereType<String>(),
      }.toList(growable: false),
      coverUrl: (cover['extraLarge'] ?? cover['large'] ?? '') as String,
      synopsis: _synopsis.summarize(json['description'] as String? ?? ''),
      status: _status(json['status'] as String?),
      rating: score == null ? null : score.toDouble() / 10,
      chapterCount: (json['chapters'] as num?)?.toInt() ?? 0,
      isAdult: json['isAdult'] as bool? ?? false,
      format: _format(json['format'] as String?),
      countryCode: json['countryOfOrigin'] as String?,
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
