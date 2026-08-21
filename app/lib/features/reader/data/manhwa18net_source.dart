import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

/// Adult serialized-manhwa fallback for Manhwa18.net.
///
/// The site exposes its public catalogue/chapter data in the Inertia
/// `#app[data-page]` payload. This adapter reads that payload directly and only
/// uses ordinary public HTTP responses; challenge/login/paywall pages are not
/// bypassed.
class Manhwa18NetSource implements MangaSource {
  Manhwa18NetSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: _baseUrl);

  static const _baseUrl = 'https://manhwa18.net';
  final Dio _client;

  @override
  String get id => 'manhwa18net';

  @override
  String get displayName => 'Manhwa18.net';

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

  Map<String, String> get _headers => const <String, String>{
    'Referer': 'https://manhwa18.net/',
    'Accept': 'text/html,application/xhtml+xml',
  };

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const <Manga>[];

    final props = await _props(
      '/tim-kiem',
      queryParameters: <String, Object>{'q': cleaned, 'page': 1},
    );
    final listing = _listing(props);
    if (listing == null) return const <Manga>[];

    final rows = listing['data'];
    if (rows is! List) return const <Manga>[];

    final result = <String, Manga>{};
    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final title =
          row['name']?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      final slug = row['slug']?.toString().trim() ?? '';
      if (title.isEmpty || slug.isEmpty) continue;
      final encoded = Uri.encodeComponent(slug);
      result[slug] = Manga(
        id: '$id:$encoded',
        title: title,
        coverUrl: _absolute(
          row['cover_url']?.toString() ?? row['thumb_url']?.toString() ?? '',
        ),
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
        isAdult: true,
      );
    }
    return result.values.toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final expected = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(SourceMatching.normalize).where((value) => value.isNotEmpty).toSet();
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      try {
        final candidates = await search(query);
        for (final candidate in candidates) {
          if (expected.contains(SourceMatching.normalize(candidate.title))) {
            return candidate.id.replaceFirst('$id:', '');
          }
        }
        final fuzzy = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: '$id:',
          minimumScore: .76,
          ambiguityMargin: .025,
        );
        if (fuzzy != null) return fuzzy;
      } catch (_) {
        // Continue through aliases, then let the repository try another source.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final slug = Uri.decodeComponent(sourceMangaId).trim();
    if (slug.isEmpty || slug.contains('/')) return null;
    final props = await _props('/manga/$slug');
    final raw = props['manga'];
    if (raw is! Map) return null;
    final manga = Map<String, dynamic>.from(raw);
    final title =
        manga['name']?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (title.isEmpty) return null;

    final statusId = (manga['status_id'] as num?)?.toInt();
    return Manga(
      id: '$id:${Uri.encodeComponent(slug)}',
      title: title,
      coverUrl: _absolute(
        manga['cover_url']?.toString() ?? manga['thumb_url']?.toString() ?? '',
      ),
      synopsis: _plain(
        manga['pilot']?.toString() ?? manga['description']?.toString() ?? '',
      ),
      status: statusId == 0
          ? MangaStatus.ongoing
          : (statusId == 1 || statusId == 2)
          ? MangaStatus.completed
          : MangaStatus.unknown,
      chapterCount: 0,
      isAdult: true,
      genres: (manga['genres'] as List? ?? const <Object>[])
          .whereType<Map>()
          .map((value) => value['name']?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final slug = Uri.decodeComponent(sourceMangaId).trim();
    if (slug.isEmpty || slug.contains('/')) return const <CanonicalChapter>[];
    final props = await _props('/manga/$slug');
    final rawChapters = props['chapters'];
    if (rawChapters is! List) return const <CanonicalChapter>[];

    final values = <CanonicalChapter>[];
    for (final raw in rawChapters.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final chapterSlug = row['slug']?.toString().trim() ?? '';
      if (chapterSlug.isEmpty) continue;
      final label =
          row['name']?.toString().replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
      final number = ChapterNumberParser.parseVisibleLabel(
        label,
        allowPlainNumber: true,
      );
      final published = _parseDate(row['created_at']?.toString());
      final path = 'manga/$slug/$chapterSlug';
      final key = number == null
          ? 'special:${_safeKey(label, chapterSlug)}'
          : 'number:${ChapterNumberParser.label(number)}';

      values.add(
        CanonicalChapter(
          id: 'chapter:$key',
          number: number,
          title: label.isEmpty
              ? number == null
                    ? 'Special'
                    : 'Chapter ${ChapterNumberParser.label(number)}'
              : label,
          publishedAt: published,
          sourceCopies: <ChapterSourceCopy>[
            ChapterSourceCopy(
              sourceId: id,
              chapterId: Uri.encodeComponent(path),
              reliability: .74,
              publishedAt: published,
              attribution: displayName,
            ),
          ],
        ),
      );
    }
    return values;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    CanonicalChapter? latest;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number == null) continue;
      if (latest == null || number > (latest.number ?? -1)) latest = chapter;
    }
    return latest ?? (chapters.isEmpty ? null : chapters.last);
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId).trim();
    if (!path.startsWith('manga/')) {
      throw const SourceFailure(
        'Invalid Manhwa18.net chapter.',
        retryable: false,
      );
    }
    final props = await _props('/$path');
    final html = props['chapterContent']?.toString() ?? '';
    if (html.isEmpty) {
      throw const SourceFailure('Manhwa18.net chapter unavailable.');
    }
    final document = html_parser.parseFragment(html);
    final seen = <String>{};
    final urls = <String>[];
    for (final image in document.querySelectorAll('img')) {
      final value = _absolute(
        image.attributes['src'] ??
            image.attributes['data-src'] ??
            image.attributes['data-lazy-src'] ??
            '',
      );
      final uri = Uri.tryParse(value);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
      if (seen.add(value)) urls.add(value);
    }
    if (urls.isEmpty || urls.length > 800) {
      throw const SourceFailure('Manhwa18.net chapter unavailable.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  Future<Map<String, dynamic>> _props(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _client.get<String>(
      path,
      queryParameters: queryParameters,
      options: Options(headers: _headers, responseType: ResponseType.plain),
    );
    final body = response.data ?? '';
    final lower = body.toLowerCase();
    if (lower.contains('just a moment') ||
        lower.contains('cf-chl-') ||
        lower.contains('cloudflare ray id')) {
      throw const SourceFailure('Manhwa18.net is protected right now.');
    }

    final document = html_parser.parse(body);
    final app = document.querySelector('#app');
    final encoded = app?.attributes['data-page']?.trim() ?? '';
    if (encoded.isEmpty) {
      throw const SourceFailure('Manhwa18.net data is unavailable.');
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const SourceFailure('Manhwa18.net data is invalid.');
    }
    final props = decoded['props'];
    if (props is! Map) {
      throw const SourceFailure('Manhwa18.net data is incomplete.');
    }
    return Map<String, dynamic>.from(props);
  }

  Map<String, dynamic>? _listing(Map<String, dynamic> props) {
    for (final key in const <String>[
      'paginate',
      'popularManga',
      'mangas',
      'latestManhwaMain',
    ]) {
      final value = props[key];
      if (value is Map) return Map<String, dynamic>.from(value);
    }
    return null;
  }

  String _plain(String raw) => (html_parser.parseFragment(raw).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _absolute(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return '';
    final uri = Uri.tryParse(cleaned);
    if (uri == null) return '';
    if (uri.hasScheme) return uri.toString();
    return Uri.parse('$_baseUrl/').resolveUri(uri).toString();
  }

  DateTime _parseDate(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    final normalized = value.contains('.')
        ? '${value.substring(0, value.indexOf('.'))}Z'
        : value;
    return DateTime.tryParse(normalized) ??
        DateTime.tryParse(value) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _safeKey(String label, String fallback) {
    final value = SourceMatching.normalize(label)
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return value.isEmpty ? fallback : value;
  }
}
