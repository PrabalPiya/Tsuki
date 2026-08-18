import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'manga_source.dart';

class AsuraSource implements MangaSource {
  AsuraSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://asuracomic.net');

  final Dio _client;

  @override
  String get id => 'asura';

  @override
  String get displayName => 'Asura';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
  );

  @override
  Set<String> get allowedImageHosts => const {};

  @override
  Future<List<Manga>> search(String query) async {
    final document = await _document(
      '/series',
      queryParameters: {'name': query},
    );

    final results = <String, Manga>{};

    final candidates = document.querySelectorAll('a[href]');

    for (final anchor in candidates) {
      final href = anchor.attributes['href'];

      if (href == null || href.isEmpty) {
        continue;
      }

      final path = _path(href);

      if (path == null || path.isEmpty || path == 'series') {
        continue;
      }

      final image = anchor.querySelector('img');

      final heading = anchor.querySelector('h3, h2, span');

      var title = (heading?.text ?? image?.attributes['alt'] ?? '').trim();

      if (title.isEmpty) {
        continue;
      }

      /*
       * Avoid navigation/category links.
       */
      if (!anchor.text.toLowerCase().contains(title.toLowerCase()) &&
          image == null) {
        continue;
      }

      final sourceId = Uri.encodeComponent(path);

      results[path] = Manga(
        id: 'asura:$sourceId',
        title: title,
        coverUrl: _absolute(
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
        ),
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
      );
    }

    return results.values.toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final expected = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(_normalize).where((value) => value.isNotEmpty).toSet();

    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      try {
        final results = await search(query);

        for (final candidate in results) {
          if (<String>{
            candidate.title,
            ...candidate.aliases,
          }.map(_normalize).any(expected.contains)) {
            return candidate.id.replaceFirst('asura:', '');
          }
        }
      } catch (_) {
        // Continue.
      }
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);

    if (path.isEmpty) {
      return null;
    }

    final document = await _document('/$path');

    final title =
        document.querySelector('h1, .series-title')?.text.trim() ?? '';

    if (title.isEmpty) {
      return null;
    }

    final coverElement = document.querySelector(
      '.series-thumb img, '
      '.thumb img, '
      'img',
    );

    return Manga(
      id: 'asura:$sourceMangaId',
      title: title,
      coverUrl: _absolute(
        coverElement?.attributes['data-src'] ??
            coverElement?.attributes['src'] ??
            '',
      ),
      synopsis:
          document
              .querySelector(
                '.series-desc, '
                '.description',
              )
              ?.text
              .trim() ??
          '',
      status: MangaStatus.unknown,
      chapterCount: document.querySelectorAll('a[href*="chapter"]').length,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);

    if (path.isEmpty) {
      return const [];
    }

    final document = await _document('/$path');

    final chapters = <String, CanonicalChapter>{};

    /*
     * Current implementations find Asura chapters
     * through chapter-list links.
     */
    final anchors = document.querySelectorAll(
      'div[class*="chapter"] a, '
      'li[class*="chapter"] a, '
      '.chapter-list a, '
      'a[href*="chapter"]',
    );

    for (final anchor in anchors) {
      final href = anchor.attributes['href'];

      if (href == null || href.isEmpty) {
        continue;
      }

      final chapterPath = _path(href);

      if (chapterPath == null || chapterPath.isEmpty) {
        continue;
      }

      final text = anchor.text.trim();

      final lowerText = text.toLowerCase();

      /*
       * Public chapters only.
       */
      if (lowerText.contains('premium') ||
          lowerText.contains('locked') ||
          lowerText.contains('subscribe')) {
        continue;
      }

      final number =
          _chapterNumber(
        text,
      );

      if (number == null) {
        continue;
      }

      final key = _numberLabel(number);

      final existing = chapters[key];

      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: Uri.encodeComponent(chapterPath),
        reliability: .70,
        publishedAt: DateTime.fromMillisecondsSinceEpoch(0),
        attribution: 'Asura',
      );

      chapters[key] = CanonicalChapter(
        id: 'chapter:number:$key',
        number: number,
        title: text.isEmpty ? 'Chapter $key' : text,
        publishedAt:
            existing?.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        sourceCopies: [...?existing?.sourceCopies, copy],
      );
    }

    final values = chapters.values.toList()
      ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

    return values;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final chapterPath = Uri.decodeComponent(sourceChapterId);

    if (chapterPath.isEmpty) {
      throw const SourceFailure('Invalid Asura chapter.', retryable: false);
    }

    final document = await _document('/$chapterPath');

    final pageText = document.body?.text.toLowerCase() ?? '';

    /*
     * Never try to bypass a locked chapter.
     */
    if (pageText.contains('premium chapter') ||
        pageText.contains('unlock chapter') ||
        pageText.contains('subscribe to read')) {
      throw const SourceFailure(
        'This Asura chapter is not publicly readable.',
        retryable: false,
      );
    }

    final urls = <String>[];

    final images = document.querySelectorAll(
      '.reader img, '
      '#readerarea img, '
      'img[src*="cdn"], '
      'img[src*="asura"]',
    );

    for (final image in images) {
      final source =
          image.attributes['data-src'] ??
          image.attributes['data-lazy-src'] ??
          image.attributes['src'];

      if (source == null || source.isEmpty) {
        continue;
      }

      final lower = source.toLowerCase();

      if (lower.contains('logo') ||
          lower.contains('avatar') ||
          lower.contains('icon') ||
          lower.contains('banner')) {
        continue;
      }

      final url = _absolute(source);

      if (!url.startsWith('https://')) {
        continue;
      }

      if (!urls.contains(url)) {
        urls.add(url);
      }
    }

    if (urls.isEmpty || urls.length > 500) {
      throw const SourceFailure('Asura chapter unavailable.');
    }

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);

    return chapters.isEmpty ? null : chapters.last;
  }

  Future<Document> _document(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _client.get<String>(
      path,
      queryParameters: queryParameters,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://asuracomic.net/'},
      ),
    );

    return html_parser.parse(response.data ?? '');
  }

  double? _chapterNumber(
  String text,
) {
  final cleaned =
      text
          .replaceAll(
            RegExp(r'\s+'),
            ' ',
          )
          .trim();

  final match =
      RegExp(
    r'\bchapter\s*#?\s*(\d+(?:\.\d+)?)\b',
    caseSensitive: false,
  ).firstMatch(cleaned);

  if (match == null) {
    return null;
  }

  return double.tryParse(
    match.group(1) ?? '',
  );
}

  String? _path(String value) {
    final uri = Uri.tryParse(value);

    if (uri == null) {
      return null;
    }

    return uri.path.replaceFirst(RegExp(r'^/+'), '');
  }

  String _absolute(String value) {
    final trimmed = value.trim();

    if (trimmed.isEmpty) {
      return '';
    }

    if (trimmed.startsWith('https://')) {
      return trimmed;
    }

    if (trimmed.startsWith('//')) {
      return 'https:$trimmed';
    }

    if (trimmed.startsWith('/')) {
      return 'https://asuracomic.net'
          '$trimmed';
    }

    return 'https://asuracomic.net/'
        '$trimmed';
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
