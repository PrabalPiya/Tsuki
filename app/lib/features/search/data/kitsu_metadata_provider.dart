import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

/// Public Kitsu JSON:API fallback. Search intentionally requests only the
/// lightweight manga fields used by result cards; details are loaded lazily.
class KitsuMetadataProvider implements MetadataProvider {
  KitsuMetadataProvider({Dio? client})
    : _client =
          client ?? createHttpClient(baseUrl: 'https://kitsu.io/api/edge');

  final Dio _client;

  @override
  String get id => 'kitsu';

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    final value = query.trim();
    if (value.length < 2) return const [];
    final response = await _client.get<Map<String, dynamic>>(
      '/manga',
      cancelToken: cancelToken,
      queryParameters: {'filter[text]': value, 'page[limit]': 20},
    );
    return _decodeList(response.data?['data']);
  }

  @override
  Future<Manga?> getById(String rawId) async {
    final id = rawId
        .replaceFirst('tsuki:kitsu:', '')
        .replaceFirst('kitsu:', '');
    if (!RegExp(r'^\d+$').hasMatch(id)) return null;
    final response = await _client.get<Map<String, dynamic>>('/manga/$id');
    final data = response.data?['data'];
    if (data is! Map) return null;
    final manga = _fromResource(Map<String, dynamic>.from(data));
    return manga.isFriendlyContent ? manga : null;
  }

  List<Manga> _decodeList(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((value) => _fromResource(Map<String, dynamic>.from(value)))
      .where((manga) => manga.isFriendlyContent)
      .toList(growable: false);

  Manga _fromResource(Map<String, dynamic> resource) {
    final id = resource['id']?.toString() ?? '';
    final attributes = resource['attributes'] is Map
        ? Map<String, dynamic>.from(resource['attributes'] as Map)
        : const <String, dynamic>{};
    final titles = attributes['titles'] is Map
        ? Map<String, dynamic>.from(attributes['titles'] as Map)
        : const <String, dynamic>{};
    final poster = attributes['posterImage'] is Map
        ? Map<String, dynamic>.from(attributes['posterImage'] as Map)
        : const <String, dynamic>{};
    final canonical = attributes['canonicalTitle']?.toString().trim();
    final title = canonical != null && canonical.isNotEmpty
        ? canonical
        : titles.values.whereType<String>().firstOrNull ?? 'Untitled';
    final ageRating = attributes['ageRating']?.toString().toUpperCase();
    final ageRatingGuide = attributes['ageRatingGuide']?.toString().trim();
    final hasUnsafeAgeGuide =
        ageRatingGuide != null &&
        ageRatingGuide.isNotEmpty &&
        !Manga.isFriendlySearchText(ageRatingGuide);
    final startDate = DateTime.tryParse(
      attributes['startDate']?.toString() ?? '',
    );
    final average = double.tryParse(
      attributes['averageRating']?.toString() ?? '',
    );

    return Manga(
      id: 'tsuki:kitsu:$id',
      kitsuId: id,
      metadataProviderIds: {'kitsu': id},
      title: title,
      aliases: <String>{
        ...titles.values.whereType<String>(),
        if (attributes['abbreviatedTitles'] is List)
          ...(attributes['abbreviatedTitles'] as List).whereType<String>(),
      }.toList(growable: false),
      coverUrl: (poster['large'] ?? poster['medium'] ?? '').toString(),
      synopsis: attributes['synopsis']?.toString() ?? '',
      status: switch (attributes['status']?.toString()) {
        'current' => MangaStatus.ongoing,
        'finished' => MangaStatus.completed,
        'tba' || 'unreleased' || 'upcoming' => MangaStatus.notYetReleased,
        _ => MangaStatus.unknown,
      },
      rating: average == null ? null : average / 10,
      chapterCount: (attributes['chapterCount'] as num?)?.toInt() ?? 0,
      volumeCount: (attributes['volumeCount'] as num?)?.toInt() ?? 0,
      startYear: startDate?.year,
      format: switch (attributes['subtype']?.toString()) {
        'novel' => MangaFormat.novel,
        'oneshot' => MangaFormat.oneShot,
        'manga' || 'manhwa' || 'manhua' => MangaFormat.manga,
        _ => MangaFormat.unknown,
      },
      countryCode: switch (attributes['subtype']?.toString()) {
        'manhwa' => 'KR',
        'manhua' => 'CN',
        _ => 'JP',
      },
      isAdult: ageRating == 'R18' || hasUnsafeAgeGuide,
    );
  }
}
