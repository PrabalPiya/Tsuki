import 'dart:developer' as developer;

import 'package:dio/dio.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'manga_source.dart';

enum _ChapterKind { numbered, special }

class _ChapterKey implements Comparable<_ChapterKey> {
  const _ChapterKey.numbered(this.raw, this.number)
    : kind = _ChapterKind.numbered;
  const _ChapterKey.special(this.raw)
    : kind = _ChapterKind.special,
      number = null;

  final _ChapterKind kind;
  final String raw;
  final double? number;

  String get idPart => switch (kind) {
    _ChapterKind.numbered => 'number:${MangaDexSource.numberLabel(number!)}',
    _ChapterKind.special => 'special:$raw',
  };

  @override
  int compareTo(_ChapterKey other) {
    final left = number;
    final right = other.number;
    if (left != null && right != null) return left.compareTo(right);
    if (left != null) return -1;
    if (right != null) return 1;
    return raw.compareTo(other.raw);
  }
}

class MangaDexFeedDiagnostic {
  const MangaDexFeedDiagnostic({
    required this.canonicalTitle,
    required this.anilistId,
    required this.matchedTitle,
    required this.mangaDexId,
    required this.contentRating,
    required this.originalLanguage,
    required this.matchReason,
    required this.matchScore,
    required this.requestUri,
    required this.statusCode,
    required this.result,
    required this.limit,
    required this.offset,
    required this.total,
    required this.rawUploads,
    required this.englishUploads,
    required this.parsedChapters,
    required this.deduplicatedChapters,
    required this.hostedUploads,
    required this.externalUploads,
    required this.discardReasons,
    required this.firstChapterNumbers,
    required this.lastChapterNumbers,
  });

  final String canonicalTitle;
  final int? anilistId;
  final String? matchedTitle;
  final String? mangaDexId;
  final String? contentRating;
  final String? originalLanguage;
  final String? matchReason;
  final int matchScore;
  final String? requestUri;
  final int? statusCode;
  final String? result;
  final int? limit;
  final int? offset;
  final int? total;
  final int rawUploads;
  final int englishUploads;
  final int parsedChapters;
  final int deduplicatedChapters;
  final int hostedUploads;
  final int externalUploads;
  final Map<String, int> discardReasons;
  final List<String> firstChapterNumbers;
  final List<String> lastChapterNumbers;

  @override
  String toString() =>
      '''
[MangaDex Diagnostic]
canonicalTitle: $canonicalTitle
anilistId: $anilistId
matchedTitle: $matchedTitle
mangaDexId: $mangaDexId
contentRating: $contentRating
originalLanguage: $originalLanguage
matchReason: $matchReason
matchScore: $matchScore
requestUri: $requestUri
statusCode: $statusCode
result: $result
limit: $limit
offset: $offset
total: $total
rawUploads: $rawUploads
englishUploads: $englishUploads
parsedChapters: $parsedChapters
deduplicatedChapters: $deduplicatedChapters
hostedUploads: $hostedUploads
externalUploads: $externalUploads
discardReasons: $discardReasons
firstChapterNumbers: $firstChapterNumbers
lastChapterNumbers: $lastChapterNumbers''';
}

class _MangaDexMatch {
  const _MangaDexMatch({
    required this.id,
    required this.title,
    required this.contentRating,
    required this.originalLanguage,
    required this.reason,
    required this.score,
  });

  final String id;
  final String title;
  final String? contentRating;
  final String? originalLanguage;
  final String reason;
  final int score;
}

class _FeedPage {
  const _FeedPage({required this.response, required this.data});

  final Response<Map<String, dynamic>> response;
  final List<Map<String, dynamic>> data;
}

class MangaDexSource implements MangaSource {
  MangaDexSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://api.mangadex.org');

  static const feedPageSize = 100;
  static const resultLimitCap = 10000;

  final Dio _client;

  @override
  String get id => 'mangadex';

  @override
  String get displayName => 'MangaDex';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const {'uploads.mangadex.org'};

  @override
  Future<List<Manga>> search(String query) => _search(query);

  Future<List<Manga>> _search(String query, {bool includeAdult = false}) async {
    final resources = await _searchResources(query, includeAdult: includeAdult);
    return resources.map(_manga).toList();
  }

  Future<List<Map<String, dynamic>>> _searchResources(
    String query, {
    bool includeAdult = false,
  }) async {
    final ratings = [
      'safe',
      'suggestive',
      if (includeAdult) ...['erotica', 'pornographic'],
    ];
    final response = await _client.get<Map<String, dynamic>>(
      '/manga',
      queryParameters: {
        'title': query,
        'limit': 20,
        'availableTranslatedLanguage[]': 'en',
        'contentRating[]': ratings,
        'includes[]': 'cover_art',
        'order[relevance]': 'desc',
      },
    );
    return _data(response);
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final response = await _client.get<Map<String, dynamic>>(
      '/manga/$sourceMangaId',
      queryParameters: {'includes[]': 'cover_art'},
    );
    final resource = response.data?['data'] as Map<String, dynamic>?;
    return resource == null ? null : _manga(resource);
  }

  Future<String?> findConservativeMatch(
    Manga canonical, {
    bool allowAdult = false,
  }) async {
    final match = await _findConservativeMatchDetails(
      canonical,
      allowAdult: allowAdult,
    );
    return match?.id;
  }

  Future<_MangaDexMatch?> _findConservativeMatchDetails(
    Manga canonical, {
    bool allowAdult = false,
  }) async {
    final expected = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(_normalize).where((title) => title.isNotEmpty).toSet();
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((title) => title.trim()).where((title) => title.length >= 2).take(8);
    for (final query in queries) {
      final match = await _findConservativeMatchForQuery(
        query,
        canonical,
        expected,
        allowAdult: allowAdult,
      );
      if (match != null) return match;
    }
    return null;
  }

  Future<_MangaDexMatch?> _findConservativeMatchForQuery(
    String query,
    Manga canonical,
    Set<String> expected, {
    required bool allowAdult,
  }) async {
    for (final resource in await _searchResources(
      query,
      includeAdult: canonical.isAdult || allowAdult,
    )) {
      final candidate = _manga(resource);
      final attrs = resource['attributes'] as Map<String, dynamic>? ?? const {};
      final contentRating = attrs['contentRating'] as String?;
      final originalLanguage = attrs['originalLanguage'] as String?;
      if (canonical.anilistId != null &&
          candidate.anilistId == canonical.anilistId) {
        return _MangaDexMatch(
          id: candidate.mangaDexId!,
          title: candidate.title,
          contentRating: contentRating,
          originalLanguage: originalLanguage,
          reason: 'AniList external id',
          score: 100,
        );
      }
      if (canonical.malId != null && candidate.malId == canonical.malId) {
        return _MangaDexMatch(
          id: candidate.mangaDexId!,
          title: candidate.title,
          contentRating: contentRating,
          originalLanguage: originalLanguage,
          reason: 'MAL external id',
          score: 95,
        );
      }
      final candidateTitles = <String>{
        candidate.title,
        ...candidate.aliases,
      }.map(_normalize).where((title) => title.isNotEmpty);
      if (candidateTitles.any(expected.contains)) {
        return _MangaDexMatch(
          id: candidate.mangaDexId!,
          title: candidate.title,
          contentRating: contentRating,
          originalLanguage: originalLanguage,
          reason: 'normalized title or alias',
          score: 80,
        );
      }
    }
    return null;
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final resources = await _fetchCompleteChapterFeed(sourceMangaId);
    return _chaptersFromResources(sourceMangaId, resources);
  }

  List<CanonicalChapter> _chaptersFromResources(
    String sourceMangaId,
    List<Map<String, dynamic>> resources,
  ) {
    final chapters = <String, CanonicalChapter>{};
    final keys = <String, _ChapterKey>{};
    for (final resource in resources) {
      final attrs = resource['attributes'] as Map<String, dynamic>? ?? const {};
      final chapterText = (attrs['chapter'] as String?)?.trim() ?? '';
      final title = (attrs['title'] as String?)?.trim() ?? '';
      final key = _chapterKey(chapterText, title, resource['id'] as String);
      final mapKey = key.idPart;
      keys[mapKey] = key;
      final number = key.number;
      final published =
          DateTime.tryParse(attrs['publishAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final existing = chapters[mapKey];
      final relationships = (resource['relationships'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      final groups = relationships
          .where((r) => r['type'] == 'scanlation_group')
          .map(
            (r) =>
                (r['attributes'] as Map<String, dynamic>?)?['name'] as String?,
          )
          .whereType<String>();
      final credit = groups.isEmpty
          ? 'MangaDex'
          : 'MangaDex - ${groups.join(', ')}';
      final externalUrl = (attrs['externalUrl'] as String?)?.trim();
      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: resource['id'] as String,
        reliability: externalUrl == null || externalUrl.isEmpty ? .9 : .35,
        publishedAt: published,
        attribution: credit,
        externalUrl: externalUrl == null || externalUrl.isEmpty
            ? null
            : externalUrl,
      );
      chapters[mapKey] = CanonicalChapter(
        id: 'chapter:$mapKey',
        number: number,
        title: _chapterTitle(number, title),
        publishedAt:
            existing == null || published.isBefore(existing.publishedAt)
            ? published
            : existing.publishedAt,
        sourceCopies: [...?existing?.sourceCopies, copy],
      );
    }
    final entries = chapters.entries.toList()
      ..sort((a, b) => keys[a.key]!.compareTo(keys[b.key]!));
    assert(() {
      // ignore: avoid_print
      print(
        '[MangaDex] Complete feed fetched mangaId=$sourceMangaId '
        'rawUploads=${resources.length} uniqueChapters=${entries.length}',
      );
      return true;
    }());
    return entries.map((entry) => entry.value).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _fetchCompleteChapterFeed(
    String sourceMangaId,
  ) async {
    final hosted = await _fetchCompleteChapterFeedVariant(
      sourceMangaId: sourceMangaId,
      includeExternalUrl: false,
    );
    final external = await _fetchCompleteChapterFeedVariant(
      sourceMangaId: sourceMangaId,
      includeExternalUrl: true,
    );
    return _mergeResources([...hosted, ...external]);
  }

  Future<List<Map<String, dynamic>>> _fetchCompleteChapterFeedVariant({
    required String sourceMangaId,
    required bool includeExternalUrl,
  }) async {
    final resources = <Map<String, dynamic>>[];
    final seenOffsets = <int>{};
    var offset = 0;
    var page = 1;
    while (true) {
      if (!seenOffsets.add(offset) || offset >= resultLimitCap) break;
      final feedPage = await _fetchChapterFeedPage(
        sourceMangaId,
        offset,
        includeExternalUrl: includeExternalUrl,
      );
      final response = feedPage.response;
      final batch = feedPage.data;
      final responseLimit = (response.data?['limit'] as num?)?.toInt();
      final total = (response.data?['total'] as num?)?.toInt();
      final effectiveLimit = responseLimit == null || responseLimit <= 0
          ? feedPageSize
          : responseLimit;
      assert(() {
        // Development-only breadcrumbs for diagnosing MangaDex feed gaps.
        // No tokens or user-identifying data are included.
        // ignore: avoid_print
        print(
          '[MangaDex] mangaId=$sourceMangaId adultEnabled=source-record '
          'requestedLanguage=en includeExternalUrl=$includeExternalUrl '
          'feedPage=$page offset=$offset '
          'received=${batch.length} total=${total ?? 'unknown'}',
        );
        return true;
      }());
      resources.addAll(batch);
      if (batch.isEmpty) break;
      if (total != null && total >= 0 && resources.length >= total) break;
      if (batch.length < effectiveLimit) break;
      offset += effectiveLimit;
      page += 1;
    }
    return resources;
  }

  Future<_FeedPage> _fetchChapterFeedPage(
    String sourceMangaId,
    int offset, {
    required bool includeExternalUrl,
  }) async {
    final queryParameters = <String, Object>{
      'manga': sourceMangaId,
      'translatedLanguage[]': 'en',
      'includeFutureUpdates': 0,
      'limit': feedPageSize,
      'offset': offset,
      'order[chapter]': 'asc',
      'order[publishAt]': 'asc',
      'includes[]': 'scanlation_group',
    };
    if (includeExternalUrl) queryParameters['includeExternalUrl'] = 1;
    final response = await _client.get<Map<String, dynamic>>(
      '/chapter',
      queryParameters: queryParameters,
    );
    return _FeedPage(response: response, data: _data(response));
  }

  List<Map<String, dynamic>> _mergeResources(
    List<Map<String, dynamic>> resources,
  ) {
    final byId = <String, Map<String, dynamic>>{};
    for (final resource in resources) {
      final id = resource['id'] as String?;
      if (id != null) byId[id] = resource;
    }
    return byId.values.toList(growable: false);
  }

  Future<MangaDexFeedDiagnostic> debugMangaDexFeed(Manga canonical) async {
    final match = await _findConservativeMatchDetails(canonical);
    if (match == null) {
      final diagnostic = MangaDexFeedDiagnostic(
        canonicalTitle: canonical.title,
        anilistId: canonical.anilistId,
        matchedTitle: null,
        mangaDexId: null,
        contentRating: null,
        originalLanguage: null,
        matchReason: null,
        matchScore: 0,
        requestUri: null,
        statusCode: null,
        result: null,
        limit: null,
        offset: null,
        total: null,
        rawUploads: 0,
        englishUploads: 0,
        parsedChapters: 0,
        deduplicatedChapters: 0,
        hostedUploads: 0,
        externalUploads: 0,
        discardReasons: const {'no confident MangaDex match': 1},
        firstChapterNumbers: const [],
        lastChapterNumbers: const [],
      );
      _debugLog(diagnostic.toString());
      return diagnostic;
    }

    final firstHostedPage = await _fetchChapterFeedPage(
      match.id,
      0,
      includeExternalUrl: false,
    );
    final firstExternalPage = await _fetchChapterFeedPage(
      match.id,
      0,
      includeExternalUrl: true,
    );
    final resources = await _fetchCompleteChapterFeed(match.id);
    final parsed = _chaptersFromResources(match.id, resources);
    final englishUploads = resources.where((resource) {
      final attrs = resource['attributes'] as Map<String, dynamic>? ?? const {};
      return attrs['translatedLanguage'] == 'en';
    }).length;
    final externalUploads = resources.where((resource) {
      final attrs = resource['attributes'] as Map<String, dynamic>? ?? const {};
      final externalUrl = (attrs['externalUrl'] as String?)?.trim();
      return externalUrl != null && externalUrl.isNotEmpty;
    }).length;
    final labels = parsed.map((chapter) => chapter.numberLabel).toList();
    final diagnostic = MangaDexFeedDiagnostic(
      canonicalTitle: canonical.title,
      anilistId: canonical.anilistId,
      matchedTitle: match.title,
      mangaDexId: match.id,
      contentRating: match.contentRating,
      originalLanguage: match.originalLanguage,
      matchReason: match.reason,
      matchScore: match.score,
      requestUri:
          'hosted=${firstHostedPage.response.realUri}; '
          'external=${firstExternalPage.response.realUri}',
      statusCode: firstHostedPage.response.statusCode,
      result: firstHostedPage.response.data?['result'] as String?,
      limit: (firstHostedPage.response.data?['limit'] as num?)?.toInt(),
      offset: (firstHostedPage.response.data?['offset'] as num?)?.toInt(),
      total: (firstHostedPage.response.data?['total'] as num?)?.toInt(),
      rawUploads: resources.length,
      englishUploads: englishUploads,
      parsedChapters: resources.length,
      deduplicatedChapters: parsed.length,
      hostedUploads: resources.length - externalUploads,
      externalUploads: externalUploads,
      discardReasons: const {},
      firstChapterNumbers: labels.take(5).toList(growable: false),
      lastChapterNumbers: labels.length <= 5
          ? labels
          : labels.skip(labels.length - 5).toList(growable: false),
    );
    _debugLog(diagnostic.toString());
    return diagnostic;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final response = await _client.get<Map<String, dynamic>>(
      '/at-home/server/$sourceChapterId',
    );
    final base = response.data?['baseUrl'] as String?;
    final chapter = response.data?['chapter'] as Map<String, dynamic>?;
    final hash = chapter?['hash'] as String?;
    final files = List<String>.from(chapter?['data'] as List? ?? const []);
    if (base == null || hash == null || files.isEmpty || files.length > 500) {
      throw const SourceFailure('Chapter unavailable right now.');
    }
    final urls = files
        .map((f) => '$base/data/$hash/$f')
        .where(_validUrl)
        .toList(growable: false);
    if (urls.length != files.length) {
      throw const SourceFailure(
        'Chapter unavailable right now.',
        retryable: false,
      );
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final values = await getChapters(sourceMangaId);
    return values.isEmpty ? null : values.last;
  }

  List<Map<String, dynamic>> _data(Response<Map<String, dynamic>> response) =>
      (response.data?['data'] as List? ?? const [])
          .cast<Map<String, dynamic>>();

  Manga _manga(Map<String, dynamic> resource) {
    final attrs = resource['attributes'] as Map<String, dynamic>? ?? const {};
    final titles = attrs['title'] as Map<String, dynamic>? ?? const {};
    final aliases = (attrs['altTitles'] as List? ?? const [])
        .expand((v) => (v as Map).values)
        .whereType<String>()
        .toList();
    final descriptions =
        attrs['description'] as Map<String, dynamic>? ?? const {};
    final links = attrs['links'] as Map<String, dynamic>? ?? const {};
    String cover = '';
    for (final rel
        in (resource['relationships'] as List? ?? const [])
            .cast<Map<String, dynamic>>()) {
      if (rel['type'] == 'cover_art') {
        final name =
            (rel['attributes'] as Map<String, dynamic>?)?['fileName']
                as String?;
        if (name != null) {
          cover =
              'https://uploads.mangadex.org/covers/${resource['id']}/$name.512.jpg';
        }
      }
    }
    final firstTitle = titles.values.whereType<String>().isEmpty
        ? 'Untitled'
        : titles.values.whereType<String>().first;
    final rating = attrs['contentRating'] as String?;
    return Manga(
      id: 'mangadex:${resource['id']}',
      anilistId: int.tryParse(links['al'] as String? ?? ''),
      malId: int.tryParse(links['mal'] as String? ?? ''),
      mangaDexId: resource['id'] as String,
      title: (titles['en'] ?? firstTitle) as String,
      aliases: aliases,
      coverUrl: cover,
      synopsis: (descriptions['en'] ?? 'Synopsis unavailable.') as String,
      status: switch (attrs['status']) {
        'ongoing' => MangaStatus.ongoing,
        'completed' => MangaStatus.completed,
        'hiatus' => MangaStatus.hiatus,
        'cancelled' => MangaStatus.cancelled,
        _ => MangaStatus.unknown,
      },
      rating: null,
      chapterCount: 0,
      isAdult: rating == 'erotica' || rating == 'pornographic',
    );
  }

  bool _validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        _publicHost(uri.host);
  }

  bool _publicHost(String host) {
    final value = host.toLowerCase();
    if (value.isEmpty || value == 'localhost' || value.endsWith('.localhost')) {
      return false;
    }
    final parts = value.split('.').map(int.tryParse).toList();
    if (parts.length == 4 && parts.every((p) => p != null)) {
      final a = parts[0]!, b = parts[1]!;
      return !(a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168));
    }
    return value != '::1' &&
        !value.startsWith('fc') &&
        !value.startsWith('fd') &&
        !value.startsWith('fe80:');
  }

  _ChapterKey _chapterKey(String chapter, String title, String uploadId) {
    final number = double.tryParse(chapter);
    if (number != null) return _ChapterKey.numbered(chapter, number);
    final special = _normalize(title).isEmpty
        ? 'upload:$uploadId'
        : 'title:${_normalize(title)}';
    return _ChapterKey.special(special);
  }

  String _chapterTitle(double? number, String title) {
    if (title.isNotEmpty) return title;
    return number == null ? 'Special' : 'Chapter ${numberLabel(number)}';
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  void _debugLog(String message) {
    assert(() {
      developer.log(message, name: 'MangaDex');
      return true;
    }());
  }

  static String numberLabel(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
