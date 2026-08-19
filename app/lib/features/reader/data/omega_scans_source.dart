import 'package:dio/dio.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';

import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

/// Omega Scans adapter for the site's current HeanCMS API.
///
/// Only freely readable chapters are exposed. Login/paid chapter support is
/// deliberately not implemented in Tsuki's public client.
class OmegaScansSource implements MangaSource {
  OmegaScansSource({Dio? client})
    : _client =
          client ?? createHttpClient(baseUrl: 'https://api.omegascans.org');

  final Dio _client;

  @override
  String get id => 'omegascans';

  @override
  String get displayName => 'Omega Scans';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const <String>{};

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const <Manga>[];

    final response = await _client.get<Map<String, dynamic>>(
      '/query',
      queryParameters: <String, Object>{
        'query_string': cleaned,
        'status': 'All',
        'order': 'desc',
        'orderBy': 'total_views',
        'series_type': 'Comic',
        'page': 1,
        'perPage': 24,
        'tags_ids': '[]',
        'adult': 'true',
      },
      options: Options(
        headers: const <String, String>{
          'Referer': 'https://omegascans.org/',
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );

    final rows = response.data?['data'];
    if (rows is! List) return const <Manga>[];

    final result = <Manga>[];
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final numericId = (row['id'] as num?)?.toInt();
      final slug = row['series_slug']?.toString().trim() ?? '';
      final title = row['title']?.toString().trim() ?? '';
      if (numericId == null || slug.isEmpty || title.isEmpty) continue;

      final encoded = Uri.encodeComponent('$numericId|$slug');
      result.add(
        Manga(
          id: 'omegascans:$encoded',
          title: title,
          coverUrl: _absolute(row['thumbnail']?.toString() ?? ''),
          synopsis: _plainDescription(row['description']?.toString() ?? ''),
          status: _status(row['status']?.toString()),
          chapterCount: 0,
          isAdult: true,
        ),
      );
    }
    return result;
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      try {
        final candidates = await search(query);
        final exact = <String>{canonical.title, ...canonical.aliases}
            .map(SourceMatching.normalize)
            .where((value) => value.isNotEmpty)
            .toSet();

        for (final candidate in candidates) {
          if (exact.contains(SourceMatching.normalize(candidate.title))) {
            return candidate.id.replaceFirst('omegascans:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'omegascans:',
          minimumScore: .78,
          ambiguityMargin: .025,
        );
        if (match != null) return match;
      } catch (_) {
        // Try another canonical alias, then another provider.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final parts = _seriesParts(sourceMangaId);
    if (parts == null) return null;

    final response = await _client.get<Map<String, dynamic>>(
      '/series/${parts.slug}',
      options: Options(
        headers: const <String, String>{
          'Referer': 'https://omegascans.org/',
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );

    final raw = response.data;
    if (raw == null) return null;
    final data = raw['data'] is Map
        ? Map<String, dynamic>.from(raw['data'] as Map)
        : raw;
    final title = data['title']?.toString().trim() ?? '';
    if (title.isEmpty) return null;

    return Manga(
      id: 'omegascans:$sourceMangaId',
      title: title,
      coverUrl: _absolute(data['thumbnail']?.toString() ?? ''),
      synopsis: _plainDescription(data['description']?.toString() ?? ''),
      status: _status(data['status']?.toString()),
      chapterCount: 0,
      isAdult: true,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final parts = _seriesParts(sourceMangaId);
    if (parts == null) return const <CanonicalChapter>[];

    final chapters = <CanonicalChapter>[];
    var page = 1;
    var lastPage = 1;

    do {
      final response = await _client.get<Map<String, dynamic>>(
        '/chapter/query',
        queryParameters: <String, Object>{
          'page': page,
          'perPage': 1000,
          'series_id': parts.id,
        },
        options: Options(
          headers: const <String, String>{
            'Referer': 'https://omegascans.org/',
            'Accept': 'application/json, text/plain, */*',
          },
        ),
      );

      final data = response.data;
      final rawRows = data?['data'];
      final rows = rawRows is List ? rawRows.whereType<Map>() : const <Map>[];

      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        final price = (row['price'] as num?)?.toInt();
        // HeanCMS marks gated chapters with a non-zero or missing price.
        if (price != 0) continue;

        final chapterId = (row['id'] as num?)?.toInt();
        final chapterSlug = row['chapter_slug']?.toString().trim() ?? '';
        final name = row['chapter_name']?.toString().trim() ?? '';
        final extraTitle = row['chapter_title']?.toString().trim() ?? '';
        if (chapterId == null || chapterSlug.isEmpty || name.isEmpty) continue;

        final number = ChapterNumberParser.parseVisibleLabel(
          name,
          allowPlainNumber: true,
        );
        final published =
            DateTime.tryParse(row['created_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
        final visibleTitle = extraTitle.isNotEmpty ? extraTitle : name;
        final encodedChapter = Uri.encodeComponent(
          '${parts.slug}|$chapterSlug|$chapterId',
        );

        chapters.add(
          CanonicalChapter(
            id: 'omegascans:$encodedChapter',
            number: number,
            title: visibleTitle,
            publishedAt: published,
            sourceCopies: <ChapterSourceCopy>[
              ChapterSourceCopy(
                sourceId: id,
                chapterId: encodedChapter,
                reliability: .90,
                publishedAt: published,
                attribution: 'Omega Scans',
              ),
            ],
          ),
        );
      }

      final meta = data?['meta'];
      if (meta is Map) {
        lastPage = (meta['last_page'] as num?)?.toInt() ?? page;
      } else {
        lastPage = page;
      }
      page++;
    } while (page <= lastPage && page <= 50);

    chapters.sort((a, b) {
      final left = a.number;
      final right = b.number;
      if (left != null && right != null) return left.compareTo(right);
      if (left != null) return -1;
      if (right != null) return 1;
      return a.publishedAt.compareTo(b.publishedAt);
    });
    return chapters;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    CanonicalChapter? latest;
    for (final chapter in chapters) {
      if (chapter.number == null) continue;
      if (latest == null || chapter.number! > (latest.number ?? -1)) {
        latest = chapter;
      }
    }
    if (latest != null) return latest;
    if (chapters.isEmpty) return null;
    chapters.sort((a, b) => a.publishedAt.compareTo(b.publishedAt));
    return chapters.last;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final decoded = Uri.decodeComponent(sourceChapterId);
    final parts = decoded.split('|');
    if (parts.length < 3) {
      return ChapterPages(
        chapterId: sourceChapterId,
        sourceId: id,
        urls: const [],
      );
    }

    final seriesSlug = parts[0];
    final chapterSlug = parts[1];
    final response = await _client.get<Map<String, dynamic>>(
      '/chapter/$seriesSlug/$chapterSlug',
      options: Options(
        headers: const <String, String>{
          'Referer': 'https://omegascans.org/',
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );

    final chapter = response.data?['chapter'];
    final chapterMap = chapter is Map
        ? Map<String, dynamic>.from(chapter)
        : const <String, dynamic>{};
    final rawData = chapterMap['chapter_data'];
    final dataMap = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : const <String, dynamic>{};
    final rawImages = dataMap['images'];
    final urls = rawImages is List
        ? rawImages
              .whereType<Object>()
              .map((value) => _absolute(value.toString()))
              .where((value) => value.startsWith('http'))
              .toList(growable: false)
        : const <String>[];

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  ({int id, String slug})? _seriesParts(String sourceMangaId) {
    final decoded = Uri.decodeComponent(sourceMangaId);
    final separator = decoded.indexOf('|');
    if (separator <= 0 || separator >= decoded.length - 1) return null;
    final numericId = int.tryParse(decoded.substring(0, separator));
    final slug = decoded.substring(separator + 1).trim();
    if (numericId == null || slug.isEmpty) return null;
    return (id: numericId, slug: slug);
  }

  String _absolute(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return '';
    if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
      return cleaned;
    }
    return 'https://api.omegascans.org/${cleaned.replaceFirst(RegExp(r'^/+'), '')}';
  }

  String _plainDescription(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\\s+'), ' ')
      .trim();

  MangaStatus _status(String? value) {
    switch (value?.toLowerCase()) {
      case 'ongoing':
        return MangaStatus.ongoing;
      case 'completed':
      case 'finished':
        return MangaStatus.completed;
      case 'hiatus':
        return MangaStatus.hiatus;
      case 'dropped':
      case 'canceled':
      case 'cancelled':
        return MangaStatus.cancelled;
      default:
        return MangaStatus.unknown;
    }
  }
}
