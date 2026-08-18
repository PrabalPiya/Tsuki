import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'manga_source.dart';

class WeebCentralSource implements MangaSource {
  WeebCentralSource({
    Dio? client,
  }) : _client =
            client ??
            createHttpClient(
              baseUrl:
                  'https://weebcentral.com',
            );

  final Dio _client;

  @override
  String get id =>
      'weebcentral';

  @override
  String get displayName =>
      'WeebCentral';

  @override
  SourceCapabilities get capabilities =>
      const SourceCapabilities(
        search: true,
        details: true,
        chapters: true,
        pages: true,
      );

  @override
  Set<String> get allowedImageHosts =>
      const {};

  @override
  Future<List<Manga>> search(
    String query,
  ) async {
    final document =
        await _document(
      '/search',
      queryParameters: {
        'text': query,
        'limit': 20,
        'offset': 0,
        'display_mode':
            'Full Display',
      },
    );

    final results =
        <String, Manga>{};

    for (final anchor
        in document.querySelectorAll(
      'a[href*="/series/"]',
    )) {
      final href =
          anchor.attributes['href'];

      if (href == null) {
        continue;
      }

      final path =
          _path(href);

      if (path == null ||
          !path.startsWith(
            'series/',
          )) {
        continue;
      }

      final image =
          anchor.querySelector('img') ??
              anchor.parent
                  ?.querySelector('img');

      final title =
          (image?.attributes['alt'] ??
                  anchor.attributes['title'] ??
                  anchor.text)
              .trim();

      if (title.isEmpty) {
        continue;
      }

      final cover =
          _absolute(
        image?.attributes['src'] ??
            image?.attributes[
                'data-src'] ??
            '',
      );

      results[path] = Manga(
        id:
            'weebcentral:${Uri.encodeComponent(path)}',
        title: title,
        coverUrl: cover,
        synopsis: '',
        status:
            MangaStatus.unknown,
        chapterCount: 0,
      );
    }

    return results.values
        .toList(
      growable: false,
    );
  }

  Future<String?> findConservativeMatch(
    Manga canonical,
  ) async {
    final expected =
        <String>{
      canonical.title,
      ...canonical.aliases,
    }
            .map(_normalize)
            .where(
              (value) =>
                  value.isNotEmpty,
            )
            .toSet();

    /*
     * Do not try 8+ aliases.
     *
     * That was a major source of the
     * loading delay.
     */
    final queries =
        <String>{
      canonical.title,
      ...canonical.aliases,
    }
            .map(
              (value) =>
                  value.trim(),
            )
            .where(
              (value) =>
                  value.length >= 2,
            )
            .take(3);

    for (final query in queries) {
      try {
        final results =
            await search(query);

        for (final candidate
            in results) {
          final names =
              <String>{
            candidate.title,
            ...candidate.aliases,
          }
                  .map(_normalize)
                  .where(
                    (value) =>
                        value.isNotEmpty,
                  );

          if (names.any(
            expected.contains,
          )) {
            return candidate.id
                .replaceFirst(
              'weebcentral:',
              '',
            );
          }
        }
      } catch (_) {}
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(
    String sourceMangaId,
  ) async {
    final path =
        Uri.decodeComponent(
      sourceMangaId,
    );

    if (!path.startsWith(
      'series/',
    )) {
      return null;
    }

    final document =
        await _document(
      '/$path',
    );

    final title =
        document
                .querySelector(
                  'h1',
                )
                ?.text
                .trim() ??
            '';

    if (title.isEmpty) {
      return null;
    }

    return Manga(
      id:
          'weebcentral:$sourceMangaId',
      title: title,
      coverUrl: '',
      synopsis:
          _longestParagraph(
        document,
      ),
      status:
          MangaStatus.unknown,
      chapterCount: 0,
    );
  }

  @override
  Future<List<CanonicalChapter>>
      getChapters(
    String sourceMangaId,
  ) async {
    final path =
        Uri.decodeComponent(
      sourceMangaId,
    );

    if (!path.startsWith(
      'series/',
    )) {
      return const [];
    }

    /*
     * CRITICAL FIX:
     *
     * Normal series page may not contain every
     * chapter.
     *
     * Fetch the dedicated full list instead.
     */
    Document document;

    try {
      document =
          await _document(
        '/$path/full-chapter-list',
      );
    } catch (_) {
      /*
       * Fall back if their full-list endpoint
       * temporarily fails.
       */
      document =
          await _document(
        '/$path',
      );
    }

    final chapters =
        <String,
            CanonicalChapter>{};

    for (final anchor
        in document.querySelectorAll(
      'a[href*="/chapters/"]',
    )) {
      final href =
          anchor.attributes['href'];

      if (href == null) {
        continue;
      }

      final chapterPath =
          _path(href);

      if (chapterPath == null ||
          !chapterPath.startsWith(
            'chapters/',
          )) {
        continue;
      }

      /*
       * IMPORTANT:
       *
       * Only parse the visible chapter label.
       * NEVER parse IDs from the URL.
       */
      final text =
          anchor.text
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      final number =
          _chapterNumber(
        text,
      );

      if (number == null) {
        continue;
      }

      final key =
          _numberLabel(
        number,
      );

      final previous =
          chapters[key];

      final copy =
          ChapterSourceCopy(
        sourceId: id,
        chapterId:
            Uri.encodeComponent(
          chapterPath,
        ),
        reliability: .72,
        publishedAt:
            DateTime
                .fromMillisecondsSinceEpoch(
          0,
        ),
        attribution:
            'WeebCentral',
      );

      chapters[key] =
          CanonicalChapter(
        id:
            'chapter:number:$key',
        number: number,
        title:
            'Chapter $key',
        publishedAt:
            previous?.publishedAt ??
                DateTime
                    .fromMillisecondsSinceEpoch(
                  0,
                ),
        sourceCopies: [
          ...?previous
              ?.sourceCopies,
          copy,
        ],
      );
    }

    final result =
        chapters.values.toList()
          ..sort(
            (a, b) =>
                (a.number ?? 0)
                    .compareTo(
              b.number ?? 0,
            ),
          );

    return result;
  }

  @override
  Future<ChapterPages>
      getChapterPages(
    String sourceChapterId,
  ) async {
    final path =
        Uri.decodeComponent(
      sourceChapterId,
    );

    if (!path.startsWith(
      'chapters/',
    )) {
      throw const SourceFailure(
        'Invalid WeebCentral chapter.',
        retryable: false,
      );
    }

    final document =
        await _document(
      '/$path',
    );

    final urls =
        <String>[];

    for (final image
        in document.querySelectorAll(
      'img',
    )) {
      final source =
          image.attributes[
                  'data-src'] ??
              image.attributes[
                  'src'];

      if (source == null ||
          source.isEmpty) {
        continue;
      }

      final lower =
          source.toLowerCase();

      if (lower.contains(
            'logo',
          ) ||
          lower.contains(
            'icon',
          ) ||
          lower.contains(
            'avatar',
          )) {
        continue;
      }

      final url =
          _absolute(
        source,
      );

      if (!url.startsWith(
        'https://',
      )) {
        continue;
      }

      if (!urls.contains(url)) {
        urls.add(url);
      }
    }

    if (urls.isEmpty ||
        urls.length > 500) {
      throw const SourceFailure(
        'WeebCentral chapter unavailable.',
      );
    }

    return ChapterPages(
      chapterId:
          sourceChapterId,
      sourceId: id,
      urls: urls,
    );
  }

  @override
  Future<CanonicalChapter?>
      getLatestChapter(
    String sourceMangaId,
  ) async {
    final chapters =
        await getChapters(
      sourceMangaId,
    );

    return chapters.isEmpty
        ? null
        : chapters.last;
  }

  Future<Document> _document(
    String path, {
    Map<String, dynamic>?
        queryParameters,
  }) async {
    final response =
        await _client.get<String>(
      path,
      queryParameters:
          queryParameters,
      options: Options(
        responseType:
            ResponseType.plain,
        headers: const {
          'Referer':
              'https://weebcentral.com/',
        },
      ),
    );

    return html_parser.parse(
      response.data ?? '',
    );
  }

  double? _chapterNumber(
    String text,
  ) {
    /*
     * Examples accepted:
     *
     * Chapter 1
     * Chapter 98
     * Ch. 12
     * Chapter 12.5
     *
     * No generic "first number found" fallback.
     */
    final match =
        RegExp(
      r'\b(?:chapter|ch\.?)\s*#?\s*(\d+(?:\.\d+)?)\b',
      caseSensitive: false,
    ).firstMatch(text);

    if (match == null) {
      return null;
    }

    return double.tryParse(
      match.group(1) ?? '',
    );
  }

  String _longestParagraph(
    Document document,
  ) {
    var result = '';

    for (final paragraph
        in document.querySelectorAll(
      'p',
    )) {
      final text =
          paragraph.text.trim();

      if (text.length >
          result.length) {
        result = text;
      }
    }

    return result;
  }

  String? _path(
    String value,
  ) {
    final uri =
        Uri.tryParse(value);

    if (uri == null) {
      return null;
    }

    return uri.path
        .replaceFirst(
          RegExp(r'^/+'),
          '',
        );
  }

  String _absolute(
    String value,
  ) {
    final trimmed =
        value.trim();

    if (trimmed.isEmpty) {
      return '';
    }

    if (trimmed.startsWith(
      'https://',
    )) {
      return trimmed;
    }

    if (trimmed.startsWith(
      '//',
    )) {
      return 'https:$trimmed';
    }

    if (trimmed.startsWith(
      '/',
    )) {
      return 'https://weebcentral.com'
          '$trimmed';
    }

    return 'https://weebcentral.com/'
        '$trimmed';
  }

  String _normalize(
    String value,
  ) =>
      value
          .toLowerCase()
          .replaceAll(
            RegExp(
              r'[^a-z0-9]',
            ),
            '',
          );

  String _numberLabel(
    double value,
  ) =>
      value ==
              value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();
}