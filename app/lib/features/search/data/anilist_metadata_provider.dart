import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

/// AniList-backed catalogue metadata.
///
/// Search uses a narrow, stable subset of AniList's manga API. Ranking feeds
/// have dedicated methods below so unused browse options cannot complicate the
/// user-facing search path.
class AniListMetadataProvider implements MetadataProvider {
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
  Future<List<Manga>> search(String query) async {
    final value = query.trim();
    if (value.length < 2) return const <Manga>[];

    final document =
        '''query SearchManga(\$search: String!) {
      Page(page: 1, perPage: 50) {
        media(type: MANGA, isAdult: false, search: \$search,
          sort: [SEARCH_MATCH, POPULARITY_DESC]) { $fields }
      }
    }''';

    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{
        'query': document,
        'variables': <String, Object?>{'search': value},
      },
    );
    return _decodePage(response);
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
    if (media is! Map) return null;
    final manga = _fromJson(Map<String, dynamic>.from(media));
    return manga.isFriendlyContent ? manga : null;
  }

  Future<List<Manga>> browseTrending() => _browseRanking('TRENDING_DESC');

  Future<List<Manga>> browsePopular() => _browseRanking('POPULARITY_DESC');

  Future<List<Manga>> browsePopularThisSeason() => _browseRanking(
    'POPULARITY_DESC',
    season: _currentSeason(),
    seasonYear: DateTime.now().year,
  );

  Future<List<Manga>> browseTopRated() => _browseRanking('SCORE_DESC');

  Future<List<Manga>> _browseRanking(
    String sort, {
    String? season,
    int? seasonYear,
  }) async {
    final seasonClause = season == null || seasonYear == null
        ? ''
        : 'season: $season, seasonYear: $seasonYear,';
    final document =
        '''query BrowseManga { Page(page: 1, perPage: 24) { media(type: MANGA, isAdult: false, $seasonClause sort: $sort) { $fields } } }''';

    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: <String, Object?>{'query': document},
    );
    return _decodePage(response);
  }

  List<Manga> _decodePage(Response<Map<String, dynamic>> response) {
    final data = response.data?['data'];
    if (data is! Map) return const <Manga>[];
    final page = data['Page'];
    if (page is! Map) return const <Manga>[];
    final media = page['media'];
    if (media is! List) return const <Manga>[];

    return media
        .whereType<Map>()
        .map((raw) => _fromJson(Map<String, dynamic>.from(raw)))
        .where((manga) => manga.isFriendlyContent)
        .toList(growable: false);
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
