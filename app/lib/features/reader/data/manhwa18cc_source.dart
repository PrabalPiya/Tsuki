import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

/// Adult serialized-webtoon fallback for Manhwa18.cc.
///
/// The selectors follow the source's current public Madara implementation:
/// search cards under `div.manga-item`, chapter rows under `li.a-h`, and
/// reader images under `div.read-content img`. Tsuki only uses ordinary public
/// HTTP responses; challenge/login/paywall pages are skipped.
class Manhwa18CcSource implements MangaSource {
  Manhwa18CcSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: _baseUrl);

  static const _baseUrl = 'https://manhwa18.cc';
  final Dio _client;

  @override
  String get id => 'manhwa18cc';

  @override
  String get displayName => 'Manhwa18.cc';

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
    'Referer': 'https://manhwa18.cc/',
    'Accept': 'text/html,application/xhtml+xml',
  };

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const <Manga>[];

    final document = await _document(
      '/search',
      queryParameters: <String, Object>{'q': cleaned, 'page': 1},
    );

    final result = <String, Manga>{};
    for (final card in document.querySelectorAll('div.manga-item')) {
      final anchor =
          card.querySelector('div.data a') ??
          card.querySelector('h3 a') ??
          card.querySelector('a[href*="/webtoon/"]');
      if (anchor == null) continue;

      final title = (anchor.attributes['title'] ?? anchor.text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (title.isEmpty || title.toLowerCase().endsWith(' raw')) continue;

      final path = _path(anchor.attributes['href'] ?? '');
      if (path == null || !path.contains('webtoon')) continue;

      final image = card.querySelector('img');
      final cover = _absolute(
        image?.attributes['data-src'] ??
            image?.attributes['data-lazy-src'] ??
            image?.attributes['src'] ??
            '',
      );
      final encoded = Uri.encodeComponent(path);
      result[path] = Manga(
        id: '$id:$encoded',
        title: title,
        coverUrl: cover,
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
        // Try the next alias, then the next adult provider.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (path.isEmpty) return null;
    final document = await _document('/$path');

    final title = (document.querySelector('h1')?.text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) return null;

    final image =
        document.querySelector('.summary_image img') ??
        document.querySelector('.info-image img');
    return Manga(
      id: '$id:$sourceMangaId',
      title: title,
      coverUrl: _absolute(
        image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
      ),
      synopsis:
          document
              .querySelector('div.panel-story-description div.dsct')
              ?.text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          '',
      status: MangaStatus.unknown,
      chapterCount: 0,
      isAdult: true,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (path.isEmpty) return const <CanonicalChapter>[];
    final document = await _document('/$path');

    final values = <CanonicalChapter>[];
    final rows = document.querySelectorAll('li.a-h');
    for (final row in rows.reversed) {
      final anchor = row.querySelector('a');
      final chapterPath = _path(anchor?.attributes['href'] ?? '');
      if (chapterPath == null) continue;

      final label = (anchor?.text ?? row.text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final number = ChapterNumberParser.parseVisibleLabel(
        label,
        allowPlainNumber: true,
      );
      final published = _parseDate(
        row.querySelector('span.chapter-time')?.text,
      );
      final key = number == null
          ? 'special:${_safeKey(label, chapterPath)}'
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
              chapterId: Uri.encodeComponent(chapterPath),
              reliability: .72,
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
    final path = Uri.decodeComponent(sourceChapterId);
    if (path.isEmpty) {
      throw const SourceFailure(
        'Invalid Manhwa18.cc chapter.',
        retryable: false,
      );
    }

    final document = await _document('/$path');
    final seen = <String>{};
    final urls = <String>[];
    for (final image in document.querySelectorAll('div.read-content img')) {
      final value = _absolute(
        image.attributes['data-src'] ??
            image.attributes['data-lazy-src'] ??
            image.attributes['data-original'] ??
            image.attributes['src'] ??
            '',
      );
      final uri = Uri.tryParse(value);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      if (seen.add(value)) urls.add(value);
    }

    if (urls.isEmpty || urls.length > 800) {
      throw const SourceFailure('Manhwa18.cc chapter unavailable.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  Future<Document> _document(
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
      throw const SourceFailure('Manhwa18.cc is protected right now.');
    }
    return html_parser.parse(body);
  }

  String? _path(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    final path = uri.path
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceAll(RegExp(r'/+$'), '');
    return path.isEmpty ? null : path;
  }

  String _absolute(String value) {
    final cleaned = value.trim();
    if (cleaned.isEmpty) return '';
    final uri = Uri.tryParse(cleaned);
    if (uri == null) return '';
    if (uri.hasScheme) return uri.toString();
    return Uri.parse('$_baseUrl/').resolveUri(uri).toString();
  }

  DateTime _parseDate(String? raw) {
    final value = raw?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (value.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    final direct = DateTime.tryParse(value);
    if (direct != null) return direct;

    const months = <String, int>{
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final match = RegExp(
      r'(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null) return DateTime.fromMillisecondsSinceEpoch(0);
    final month = months[match.group(2)!.substring(0, 3).toLowerCase()];
    if (month == null) return DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
    );
  }

  String _safeKey(String label, String path) {
    final normalized = SourceMatching.normalize(label);
    if (normalized.isNotEmpty) return normalized;
    return path.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
  }
}
