import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart'
    as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';

import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

class WeebCentralSource
    implements MangaSource {
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
  SourceCapabilities
      get capabilities =>
          const SourceCapabilities(
            search: true,
            details: true,
            chapters: true,
            pages: true,
          );

  @override
  Set<String>
      get allowedImageHosts =>
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
        'limit': 30,
        'offset': 0,
        'display_mode':
            'Full Display',
      },
    );

    final results =
        <String, Manga>{};

    for (final anchor
        in document
            .querySelectorAll(
      'a[href*="/series/"]',
    )) {
      final href =
          anchor.attributes[
              'href'];

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

      final container =
          anchor.parent;

      final image =
          anchor.querySelector(
            'img',
          ) ??
          container?.querySelector(
            'img',
          );

      var title =
          (image?.attributes[
                      'alt'] ??
                  anchor.attributes[
                      'title'] ??
                  anchor.text)
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      if (title.isEmpty) {
        continue;
      }

      final cover =
          _absolute(
        image?.attributes[
                'src'] ??
            image?.attributes[
                'data-src'] ??
            '',
      );

      final encoded =
          Uri.encodeComponent(
        path,
      );

      results[path] = Manga(
        id:
            'weebcentral:$encoded',
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

  Future<String?>
      findConservativeMatch(
    Manga canonical,
  ) async {
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
            .take(4)
            .toList();

    final candidates =
        <String, Manga>{};

    for (final query in queries) {
      try {
        final values =
            await search(query);

        for (final value in values) {
          candidates[value.id] =
              value;
        }
      } catch (_) {
        // Another alias may work.
      }
    }

    return SourceMatching.bestMatchId(
      canonical,
      candidates.values.toList(),
      sourcePrefix:
          'weebcentral:',
      minimumScore: .84,
    );
  }

  @override
  Future<Manga?>
      getMangaDetails(
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

    final aliases =
        <String>{};

    for (final element
        in document
            .querySelectorAll(
      'li, div, p',
    )) {
      final text =
          element.text
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      if (!text
          .toLowerCase()
          .contains(
            'associated name',
          )) {
        continue;
      }

      final links =
          element.querySelectorAll(
        'a',
      );

      for (final link in links) {
        final alias =
            link.text.trim();

        if (alias.isNotEmpty) {
          aliases.add(alias);
        }
      }
    }

    return Manga(
      id:
          'weebcentral:$sourceMangaId',
      title: title,
      aliases:
          aliases.toList(),
      coverUrl: '',
      synopsis:
          _longestParagraph(
        document,
      ),
      status:
          MangaStatus.unknown,
      chapterCount:
          _visibleChapterCount(
        document,
      ),
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
     * WeebCentral's normal page intentionally
     * shows newest + oldest chapters with a
     * "Show All Chapters" control.
     *
     * Use the complete list endpoint first.
     */
    Document document;

    try {
      document =
          await _document(
        '/$path/full-chapter-list',
      );

      if (document
          .querySelectorAll(
            'a[href*="/chapters/"]',
          )
          .isEmpty) {
        throw const SourceFailure(
          'Full chapter list returned no chapters.',
        );
      }
    } catch (_) {
      document =
          await _document(
        '/$path',
      );
    }

    final chapters =
        <String,
            CanonicalChapter>{};

    for (final anchor
        in document
            .querySelectorAll(
      'a[href*="/chapters/"]',
    )) {
      final href =
          anchor.attributes[
              'href'];

      if (href == null) {
        continue;
      }

      final chapterPath =
          _path(href);

      if (chapterPath == null ||
          !chapterPath
              .startsWith(
            'chapters/',
          )) {
        continue;
      }

      final text =
          anchor.text
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      final number =
          ChapterNumberParser
              .parseVisibleLabel(
        text,
        allowPlainNumber: true,
      );

      if (number == null) {
        continue;
      }

      final key =
          ChapterNumberParser.label(
        number,
      );

      final existing =
          chapters[key];

      final published =
          _nearbyDate(
        anchor,
      );

      final copy =
          ChapterSourceCopy(
        sourceId: id,
        chapterId:
            Uri.encodeComponent(
          chapterPath,
        ),
        reliability: .82,
        publishedAt:
            published,
        attribution:
            'WeebCentral',
      );

      chapters[key] =
          CanonicalChapter(
        id:
            'chapter:number:$key',
        number: number,
        title: text.isEmpty
            ? 'Chapter $key'
            : text,
        publishedAt:
            existing == null ||
                    published.isBefore(
                      existing
                          .publishedAt,
                    )
                ? published
                : existing
                    .publishedAt,
        sourceCopies: [
          ...?existing
              ?.sourceCopies,
          copy,
        ],
      );
    }

    final values =
        chapters.values.toList()
          ..sort(
            (a, b) =>
                (a.number ?? 0)
                    .compareTo(
              b.number ?? 0,
            ),
          );

    return values;
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

    /*
     * Prefer reader/page images.
     */
    final candidates =
        document.querySelectorAll(
      '#reader img, '
      '.reader img, '
      'main img, '
      'img',
    );

    for (final image
        in candidates) {
      final raw =
          image.attributes[
                  'data-src'] ??
              image.attributes[
                  'data-lazy-src'] ??
              image.attributes[
                  'src'];

      if (raw == null ||
          raw.trim().isEmpty) {
        continue;
      }

      final lower =
          raw.toLowerCase();

      if (lower.contains(
            'logo',
          ) ||
          lower.contains(
            'avatar',
          ) ||
          lower.contains(
            'icon',
          ) ||
          lower.contains(
            'banner',
          )) {
        continue;
      }

      final url =
          _absolute(raw);

      final uri =
          Uri.tryParse(url);

      if (uri == null ||
          uri.scheme != 'https') {
        continue;
      }

      if (!urls.contains(url)) {
        urls.add(url);
      }
    }

    if (urls.isEmpty ||
        urls.length > 600) {
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

  DateTime _nearbyDate(
    Element anchor,
  ) {
    Element? node =
        anchor.parent;

    for (var depth = 0;
        depth < 4 &&
            node != null;
        depth++) {
      final time =
          node.querySelector(
        'time',
      );

      final raw =
          time?.attributes[
                  'datetime'] ??
              time?.text;

      if (raw != null) {
        final parsed =
            DateTime.tryParse(
          raw.trim(),
        );

        if (parsed != null) {
          return parsed;
        }
      }

      node = node.parent;
    }

    return DateTime
        .fromMillisecondsSinceEpoch(
      0,
    );
  }

  int _visibleChapterCount(
    Document document,
  ) {
    final pattern =
        RegExp(
      r'(\d+)\s+chapters?',
      caseSensitive: false,
    );

    final match =
        pattern.firstMatch(
      document.body?.text ?? '',
    );

    return int.tryParse(
          match?.group(1) ?? '',
        ) ??
        0;
  }

  String _longestParagraph(
    Document document,
  ) {
    var result = '';

    for (final paragraph
        in document
            .querySelectorAll(
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
}