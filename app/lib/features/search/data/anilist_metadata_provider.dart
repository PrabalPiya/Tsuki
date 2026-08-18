import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

class AniListMetadataProvider implements MetadataProvider {
  AniListMetadataProvider({Dio? client, SynopsisService? synopsisService})
    : _client =
          client ?? createHttpClient(baseUrl: 'https://graphql.anilist.co'),
      _synopsis = synopsisService ?? const DeterministicSynopsisService();
  final Dio _client;
  final SynopsisService _synopsis;
  @override
  String get id => 'anilist';

  static const fields = r'''id idMal title { romaji english native } synonyms description(asHtml: false)
    status averageScore coverImage { extraLarge large } chapters isAdult''';

  @override
  Future<List<Manga>> search(String query, {required bool includeAdult}) async {
    final document =
        '''query SearchManga(\$search: String!, \$isAdult: Boolean) {
      Page(page: 1, perPage: 24) { media(search: \$search, type: MANGA, isAdult: \$isAdult, sort: SEARCH_MATCH) { $fields } }
    }''';
    final variables = <String, Object?>{'search': query};
    if (!includeAdult) variables['isAdult'] = false;
    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: {'query': document, 'variables': variables},
    );
    final page =
        (response.data?['data'] as Map<String, dynamic>?)?['Page']
            as Map<String, dynamic>?;
    return (page?['media'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_fromJson)
        .where((m) => includeAdult || !m.isAdult)
        .toList();
  }

  @override
  Future<Manga?> getById(String id) async {
    final value = int.tryParse(id.replaceFirst('anilist:', ''));
    if (value == null) return null;
    final document =
        '''query Manga(\$id: Int!) { Media(id: \$id, type: MANGA) { $fields } }''';
    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: {
        'query': document,
        'variables': {'id': value},
      },
    );
    final media =
        (response.data?['data'] as Map<String, dynamic>?)?['Media']
            as Map<String, dynamic>?;
    return media == null ? null : _fromJson(media);
  }

  Future<List<Manga>> browseTrending() => _browse('TRENDING_DESC');
  Future<List<Manga>> browsePopular() => _browse('POPULARITY_DESC');
  Future<List<Manga>> browsePopularThisSeason() => _browse(
    'POPULARITY_DESC',
    season: _currentSeason(),
    seasonYear: DateTime.now().year,
  );
  Future<List<Manga>> browseTopRated() => _browse('SCORE_DESC');

  Future<List<Manga>> _browse(
    String sort, {
    String? season,
    int? seasonYear,
  }) async {
    final seasonClause = season == null || seasonYear == null
        ? ''
        : 'season: $season, seasonYear: $seasonYear,';
    final document =
        '''query BrowseManga {
      Page(page: 1, perPage: 24) { media(type: MANGA, isAdult: false, $seasonClause sort: $sort) { $fields } }
    }''';
    final response = await _client.post<Map<String, dynamic>>(
      '',
      data: {'query': document},
    );
    final page =
        (response.data?['data'] as Map<String, dynamic>?)?['Page']
            as Map<String, dynamic>?;
    return (page?['media'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_fromJson)
        .toList();
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
    final score = json['averageScore'] as num?;
    final id = json['id'] as int;
    return Manga(
      id: 'anilist:$id',
      anilistId: id,
      title:
          (title['english'] ?? title['romaji'] ?? title['native'] ?? 'Untitled')
              as String,
      aliases: <String>{
        ...title.values.whereType<String>(),
        ...(json['synonyms'] as List? ?? const []).whereType<String>(),
      }.toList(),
      coverUrl: (cover['extraLarge'] ?? cover['large'] ?? '') as String,
      synopsis: _synopsis.summarize(json['description'] as String? ?? ''),
      status: _status(json['status'] as String?),
      rating: score == null ? null : score.toDouble() / 10,
      chapterCount: json['chapters'] as int? ?? 0,
      isAdult: json['isAdult'] as bool? ?? false,
    );
  }

  MangaStatus _status(String? value) => switch (value) {
    'RELEASING' => MangaStatus.ongoing,
    'FINISHED' => MangaStatus.completed,
    'HIATUS' => MangaStatus.hiatus,
    'CANCELLED' => MangaStatus.cancelled,
    _ => MangaStatus.unknown,
  };
}
