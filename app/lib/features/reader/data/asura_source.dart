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

class AsuraSource
    implements MangaSource {
  AsuraSource({
    Dio? client,
  }) : _client =
            client ??
            createHttpClient(
              baseUrl:
                  'https://asurascans.com',
            );

  final Dio _client;

  List<Manga>? _indexCache;

  DateTime? _indexCachedAt;

  @override
  String get id => 'asura';

  @override
  String get displayName =>
      'Asura';

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
          const {
            'cdn.asurascans.com',
          };

  @override
  Future<List<Manga>> search(
    String query,
  ) async {
    final index =
        await _loadIndex();

    final scored =
        <({Manga manga, double score})>[];

    for (final manga in index) {
      final score =
          SourceMatching.similarity(
        query,
        manga.title,
      );

      if (score >= .60) {
        scored.add(
          (
            manga: manga,
            score: score,
          ),
        );
      }
    }

    scored.sort(
      (a, b) =>
          b.score.compareTo(
        a.score,
      ),
    );

    return scored
        .take(30)
        .map(
          (entry) =>
              entry.manga,
        )
        .toList(
          growable: false,
        );
  }

  Future<String?>
      findConservativeMatch(
    Manga canonical,
  ) async {
    final candidates =
        await _loadIndex();

    return SourceMatching.bestMatchId(
      canonical,
      candidates,
      sourcePrefix: 'asura:',
      minimumScore: .87,
      ambiguityMargin: .04,
    );
  }

  /*
   * Asura currently has a few hundred titles.
   *
   * Load the browse catalogue once and keep it
   * cached instead of hitting /browse for every
   * alias search.
   */
  Future<List<Manga>>
      _loadIndex() async {
    final now =
        DateTime.now();

    final cached =
        _indexCache;

    final cachedAt =
        _indexCachedAt;

    if (cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) <
            const Duration(
              minutes: 30,
            )) {
      return cached;
    }

    final results =
        <String, Manga>{};

    /*
     * Current Asura browse pages expose roughly
     * twenty titles at a time.
     *
     * Stop when pages stop producing new comics.
     */
    var emptyOrDuplicatePages = 0;

    for (var page = 1;
        page <= 25;
        page++) {
      try {
        final document =
            await _document(
          '/browse',
          queryParameters: {
            'page': page,
          },
        );

        final before =
            results.length;

        for (final anchor
            in document
                .querySelectorAll(
          'a[href*="/comics/"]',
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
                'comics/',
              )) {
            continue;
          }

          /*
           * Do not treat chapter links as
           * separate manga.
           */
          if (path.contains(
            '/chapter/',
          )) {
            continue;
          }

          final image =
              anchor.querySelector(
                'img',
              );

          String title =
              (image?.attributes[
                          'alt'] ??
                      anchor
                          .querySelector(
                            'h1, h2, h3, h4',
                          )
                          ?.text ??
                      '')
                  .replaceAll(
                    RegExp(r'\s+'),
                    ' ',
                  )
                  .trim();

          if (title.isEmpty) {
            /*
             * Slug is still useful as a
             * fallback title.
             */
            title =
                _titleFromPath(
              path,
            );
          }

          if (title.isEmpty) {
            continue;
          }

          final sourceId =
              Uri.encodeComponent(
            path,
          );

          results[path] = Manga(
            id:
                'asura:$sourceId',
            title: title,
            coverUrl:
                _absolute(
              image?.attributes[
                      'src'] ??
                  image?.attributes[
                      'data-src'] ??
                  '',
            ),
            synopsis: '',
            status:
                MangaStatus.unknown,
            chapterCount:
                _chapterCountFromCard(
              anchor.text,
            ),
          );
        }

        if (results.length ==
            before) {
          emptyOrDuplicatePages++;

          if (emptyOrDuplicatePages >=
              2) {
            break;
          }
        } else {
          emptyOrDuplicatePages = 0;
        }
      } catch (_) {
        /*
         * A missing late pagination page should
         * not destroy the catalogue already read.
         */
        if (results.isNotEmpty) {
          break;
        }

        rethrow;
      }
    }

    final values =
        results.values.toList(
      growable: false,
    );

    _indexCache = values;
    _indexCachedAt = now;

    return values;
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
      'comics/',
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
                .replaceAll(
                  RegExp(r'\s+'),
                  ' ',
                )
                .trim() ??
            '';

    if (title.isEmpty) {
      return null;
    }

    final aliases =
        _extractAliases(
      document,
      title,
    );

    final cover =
        _findCover(
      document,
      title,
    );

    return Manga(
      id:
          'asura:$sourceMangaId',
      title: title,
      aliases: aliases,
      coverUrl: cover,
      synopsis:
          _findDescription(
        document,
      ),
      status:
          _statusFromDocument(
        document,
      ),
      chapterCount:
          _seriesChapterCount(
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
      'comics/',
    )) {
      return const [];
    }

    final document =
        await _document(
      '/$path',
    );

    final chapters =
        <String,
            CanonicalChapter>{};

    /*
     * Current Asura series pages expose their
     * complete chapter listing directly.
     */
    for (final anchor
        in document
            .querySelectorAll(
      'a[href*="/chapter/"]',
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
          !chapterPath.startsWith(
            '$path/chapter/',
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

      final lower =
          text.toLowerCase();

      /*
       * Do not circumvent premium chapters.
       */
      if (lower.contains(
            'premium',
          ) ||
          lower.contains(
            'locked',
          ) ||
          lower.contains(
            'subscribe',
          )) {
        continue;
      }

      final number =
          ChapterNumberParser
              .parseVisibleLabel(
        text,
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
          _dateNearAnchor(
        anchor,
      );

      final copy =
          ChapterSourceCopy(
        sourceId: id,
        chapterId:
            Uri.encodeComponent(
          chapterPath,
        ),
        reliability: .78,
        publishedAt:
            published,
        attribution: 'Asura',
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
          'comics/',
        ) ||
        !path.contains(
          '/chapter/',
        )) {
      throw const SourceFailure(
        'Invalid Asura chapter.',
        retryable: false,
      );
    }

    final document =
        await _document(
      '/$path',
    );

    final pageText =
        document.body
                ?.text
                .toLowerCase() ??
            '';

    if (pageText.contains(
          'premium chapter',
        ) ||
        pageText.contains(
          'unlock chapter',
        ) ||
        pageText.contains(
          'subscribe to read',
        )) {
      throw const SourceFailure(
        'This Asura chapter is not publicly readable.',
        retryable: false,
      );
    }

    final urls =
        <String>[];

    final images =
        document
            .querySelectorAll(
      'main img, '
      '.reader img, '
      '#readerarea img, '
      'img[src*="cdn.asurascans.com"]',
    );

    for (final image in images) {
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
            'cover',
          ) ||
          lower.contains(
            'banner',
          ) ||
          lower.contains(
            'icon',
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
        'Asura chapter unavailable.',
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
    final values =
        await getChapters(
      sourceMangaId,
    );

    return values.isEmpty
        ? null
        : values.last;
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
              'https://asurascans.com/',
        },
      ),
    );

    return html_parser.parse(
      response.data ?? '',
    );
  }

  List<String> _extractAliases(
    Document document,
    String title,
  ) {
    final aliases =
        <String>{};

    final normalizedTitle =
        SourceMatching.normalize(
      title,
    );

    /*
     * Current page places aliases near the
     * primary H1 before the description.
     */
    for (final element
        in document
            .querySelectorAll(
      'p, div',
    )) {
      final text =
          element.text
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      if (!text.contains('•')) {
        continue;
      }

      final pieces =
          text
              .split('•')
              .map(
                (value) =>
                    value.trim(),
              )
              .where(
                (value) =>
                    value.isNotEmpty &&
                    value.length < 100,
              );

      for (final value in pieces) {
        if (SourceMatching.normalize(
              value,
            ) !=
            normalizedTitle) {
          aliases.add(value);
        }
      }

      if (aliases.isNotEmpty) {
        break;
      }
    }

    return aliases.toList(
      growable: false,
    );
  }

  String _findCover(
    Document document,
    String title,
  ) {
    for (final image
        in document
            .querySelectorAll(
      'img',
    )) {
      final alt =
          image.attributes[
                  'alt'] ??
              '';

      if (SourceMatching.similarity(
            alt,
            title,
          ) <
          .85) {
        continue;
      }

      return _absolute(
        image.attributes[
                'src'] ??
            image.attributes[
                'data-src'] ??
            '',
      );
    }

    return '';
  }

  String _findDescription(
    Document document,
  ) {
    var longest = '';

    for (final paragraph
        in document
            .querySelectorAll(
      'p',
    )) {
      final text =
          paragraph.text.trim();

      if (text.length >
              longest.length &&
          text.length > 80) {
        longest = text;
      }
    }

    return longest;
  }

  MangaStatus _statusFromDocument(
    Document document,
  ) {
    final text =
        document.body?.text
                .toLowerCase() ??
            '';

    if (text.contains(
      'status completed',
    )) {
      return MangaStatus.completed;
    }

    if (text.contains(
      'status hiatus',
    )) {
      return MangaStatus.hiatus;
    }

    if (text.contains(
      'status cancelled',
    )) {
      return MangaStatus.cancelled;
    }

    if (text.contains(
      'status ongoing',
    )) {
      return MangaStatus.ongoing;
    }

    return MangaStatus.unknown;
  }

  int _seriesChapterCount(
    Document document,
  ) {
    final match =
        RegExp(
      r'(\d+)\s+chapters?',
      caseSensitive: false,
    ).firstMatch(
      document.body?.text ?? '',
    );

    return int.tryParse(
          match?.group(1) ?? '',
        ) ??
        0;
  }

  int _chapterCountFromCard(
    String text,
  ) {
    final match =
        RegExp(
      r'(\d+)\s+(?:chs?|chapters?)',
      caseSensitive: false,
    ).firstMatch(text);

    return int.tryParse(
          match?.group(1) ?? '',
        ) ??
        0;
  }

  DateTime _dateNearAnchor(
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

  String _titleFromPath(
    String path,
  ) {
    var slug =
        path.replaceFirst(
      'comics/',
      '',
    );

    slug = slug.replaceFirst(
      RegExp(
        r'-[a-f0-9]{8}$',
        caseSensitive: false,
      ),
      '',
    );

    return slug
        .split('-')
        .where(
          (value) =>
              value.isNotEmpty,
        )
        .map(
          (value) =>
              '${value[0].toUpperCase()}'
              '${value.substring(1)}',
        )
        .join(' ');
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
      return 'https://asurascans.com'
          '$trimmed';
    }

    return 'https://asurascans.com/'
        '$trimmed';
  }
}