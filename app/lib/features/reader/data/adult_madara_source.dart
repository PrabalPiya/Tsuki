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

/// Small ordinary-HTTP adapter for adult Madara sites.
///
/// It intentionally does not try to bypass challenge pages or access gated
/// content. A protected/unavailable source simply falls through to the next
/// provider in CatalogRepository.
class AdultMadaraSource implements MangaSource {
  AdultMadaraSource({
    required this.id,
    required this.displayName,
    required this.baseUrl,
    Dio? client,
  }) : _client = client ?? createHttpClient(baseUrl: baseUrl);

  @override
  final String id;

  @override
  final String displayName;

  final String baseUrl;
  final Dio _client;

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

  Map<String, String> get _headers => <String, String>{
    'Referer': '$baseUrl/',
    'Accept': 'text/html,application/xhtml+xml',
  };

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const <Manga>[];

    final document = await _document(
      '/',
      queryParameters: <String, dynamic>{'s': cleaned, 'post_type': 'wp-manga'},
    );

    final byPath = <String, Manga>{};
    final cards = <Element>[
      ...document.querySelectorAll('div.c-tabs-item__content'),
      ...document.querySelectorAll('.manga__item'),
    ];

    for (final card in cards) {
      final anchor =
          card.querySelector('div.post-title a') ??
          card.querySelector('h3 a') ??
          card.querySelector('a[href]');
      if (anchor == null) continue;

      final path = _path(anchor.attributes['href'] ?? '');
      final title = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (path == null || title.isEmpty) continue;

      final image = card.querySelector('img');
      final cover = _absolute(
        image?.attributes['data-src'] ??
            image?.attributes['data-lazy-src'] ??
            image?.attributes['data-original'] ??
            image?.attributes['src'] ??
            '',
      );

      final sourceMangaId = Uri.encodeComponent(path);
      byPath[path] = Manga(
        id: '$id:$sourceMangaId',
        title: title,
        coverUrl: cover,
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
        isAdult: true,
      );
    }

    return byPath.values.toList(growable: false);
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
        if (candidates.isEmpty) continue;

        for (final candidate in candidates) {
          final candidateNames = <String>{
            candidate.title,
            ...candidate.aliases,
          }.map(SourceMatching.normalize);
          if (candidateNames.any(expected.contains)) {
            return candidate.id.replaceFirst('$id:', '');
          }
        }

        final fuzzy = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: '$id:',
          minimumScore: .78,
          ambiguityMargin: .03,
        );
        if (fuzzy != null) return fuzzy;
      } catch (_) {
        // Try another alias/provider.
      }
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (path.isEmpty) return null;

    final document = await _document('/$path');
    final title =
        document.querySelector('.post-title h1')?.text.trim() ??
        document.querySelector('h1')?.text.trim() ??
        '';
    if (title.isEmpty) return null;

    final image = document.querySelector('.summary_image img');
    return Manga(
      id: '$id:$sourceMangaId',
      title: title,
      coverUrl: _absolute(
        image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
      ),
      synopsis: document.querySelector('.summary__content')?.text.trim() ?? '',
      status: MangaStatus.unknown,
      chapterCount: 0,
      isAdult: true,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (path.isEmpty) return const <CanonicalChapter>[];

    var document = await _document('/$path');
    var rows = document.querySelectorAll('li.wp-manga-chapter');

    if (rows.isEmpty &&
        document.querySelector('div[id^="manga-chapters-holder"]') != null) {
      try {
        final response = await _client.post<String>(
          '/$path/ajax/chapters',
          options: Options(
            headers: <String, String>{
              ..._headers,
              'X-Requested-With': 'XMLHttpRequest',
              'Accept': 'text/html,*/*',
            },
            responseType: ResponseType.plain,
          ),
        );
        final body = response.data ?? '';
        _ensureOrdinaryPage(body);
        document = html_parser.parse(body);
        rows = document.querySelectorAll('li.wp-manga-chapter');
      } catch (_) {
        // Keep the original page result.
      }
    }

    final values = <CanonicalChapter>[];
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
        row.querySelector('span.chapter-release-date')?.text,
      );
      final key = number == null
          ? 'special:${_safeKey(label, chapterPath)}'
          : 'number:${ChapterNumberParser.label(number)}';

      values.add(
        CanonicalChapter(
          id: 'chapter:$key',
          number: number,
          title: label.isEmpty
              ? (number == null
                    ? 'Special'
                    : 'Chapter ${ChapterNumberParser.label(number)}')
              : label,
          publishedAt: published,
          sourceCopies: <ChapterSourceCopy>[
            ChapterSourceCopy(
              sourceId: id,
              chapterId: Uri.encodeComponent(chapterPath),
              reliability: .60,
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
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (path.isEmpty) {
      throw SourceFailure('Invalid $displayName chapter.', retryable: false);
    }

    final document = await _document('/$path');
    final urls = <String>[];
    final seen = <String>{};

    for (final selector in const <String>[
      'div.page-break img',
      'li.blocks-gallery-item img',
      '.reading-content img',
      '.reading-content .text-left img',
    ]) {
      for (final image in document.querySelectorAll(selector)) {
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
    }

    if (urls.isEmpty || urls.length > 700) {
      throw SourceFailure('$displayName chapter unavailable.');
    }

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    CanonicalChapter? latestNumbered;
    CanonicalChapter? latestDated;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number != null &&
          (latestNumbered == null || number > (latestNumbered.number ?? -1))) {
        latestNumbered = chapter;
      }
      if (latestDated == null ||
          chapter.publishedAt.isAfter(latestDated.publishedAt)) {
        latestDated = chapter;
      }
    }
    return latestNumbered ?? latestDated;
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
    _ensureOrdinaryPage(body);
    return html_parser.parse(body);
  }

  void _ensureOrdinaryPage(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('just a moment') ||
        lower.contains('cf-chl-') ||
        lower.contains('cloudflare ray id')) {
      throw SourceFailure('$displayName is protected right now.');
    }
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
    return Uri.parse('$baseUrl/').resolveUri(uri).toString();
  }

  DateTime _parseDate(String? value) {
    final raw = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
    if (raw.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct;

    final match = RegExp(r'([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})').firstMatch(raw);
    if (match == null) return DateTime.fromMillisecondsSinceEpoch(0);

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
    final month = months[match.group(1)!.substring(0, 3).toLowerCase()];
    final day = int.tryParse(match.group(2)!);
    final year = int.tryParse(match.group(3)!);
    if (month == null || day == null || year == null) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime(year, month, day);
  }

  String _safeKey(String label, String path) {
    final normalized = SourceMatching.normalize(label);
    return normalized.isEmpty
        ? path.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-')
        : normalized.replaceAll(' ', '-');
  }
}
