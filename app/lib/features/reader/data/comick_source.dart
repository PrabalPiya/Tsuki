import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart'
    as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';

import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

class ComicKSource
    implements MangaSource {
  ComicKSource({
    Dio? apiClient,
    Dio? webClient,
  })  : _apiClient =
            apiClient ??
            createHttpClient(
              baseUrl:
                  'https://api.comick.io',
            ),
        _webClient =
            webClient ??
            createHttpClient(
              baseUrl:
                  'https://comick.io',
            );

  final Dio _apiClient;
  final Dio _webClient;

  @override
  String get id => 'comick';

  @override
  String get displayName =>
      'ComicK';

  @override
  SourceCapabilities
      get capabilities =>
          const SourceCapabilities(
            search: true,
            chapters: true,
            pages: true,
          );

  @override
  Set<String>
      get allowedImageHosts =>
          const {
            'meo.comick.pictures',
          };

  @override
  Future<List<Manga>> search(
    String query,
  ) async {
    final rows =
        await _searchRows(
      query,
    );

    return rows
        .map(_toManga)
        .whereType<Manga>()
        .toList(
          growable: false,
        );
  }

  Future<String?>
      findConservativeMatch(
    Manga canonical,
  ) async {
    final candidates =
        <String, Manga>{};

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
            .take(4);

    for (final query in queries) {
      try {
        for (final manga
            in await search(query)) {
          candidates[manga.id] =
              manga;
        }
      } catch (_) {}
    }

    return SourceMatching.bestMatchId(
      canonical,
      candidates.values.toList(),
      sourcePrefix: 'comick:',
      minimumScore: .85,
    );
  }

  Future<List<
          Map<String, dynamic>>>
      _searchRows(
    String query,
  ) async {
    final response =
        await _apiClient
            .get<dynamic>(
      '/v1.0/search',
      queryParameters: {
        'q': query,
        'limit': 30,
      },
      options: Options(
        headers: const {
          'Referer':
              'https://comick.io/',
        },
      ),
    );

    final raw =
        response.data;

    if (raw is! List) {
      return const [];
    }

    return raw
        .whereType<Map>()
        .map(
          (value) =>
              Map<String, dynamic>
                  .from(value),
        )
        .toList(
          growable: false,
        );
  }

  Manga? _toManga(
    Map<String, dynamic> row,
  ) {
    final hid =
        row['hid']?.toString();

    final slug =
        row['slug']?.toString();

    final title =
        row['title']?.toString();

    if (hid == null ||
        slug == null ||
        title == null ||
        title.isEmpty) {
      return null;
    }

    final aliases =
        (row['md_titles']
                    as List? ??
                const [])
            .whereType<Map>()
            .map(
              (value) =>
                  value['title'],
            )
            .whereType<String>()
            .toList(
              growable: false,
            );

    final contentRating =
        row['content_rating']
            ?.toString();

    String cover = '';

    for (final item
        in (row['md_covers']
                    as List? ??
                const [])
            .whereType<Map>()) {
      final key =
          item['b2key']
              ?.toString();

      if (key == null ||
          key.isEmpty) {
        continue;
      }

      cover =
          'https://meo.comick.pictures/$key';

      break;
    }

    return Manga(
      id:
          'comick:${Uri.encodeComponent(hid)}|'
          '${Uri.encodeComponent(slug)}',
      title: title,
      aliases: aliases,
      coverUrl: cover,
      synopsis:
          row['desc']?.toString() ??
              '',
      status:
          MangaStatus.unknown,
      chapterCount:
          _intValue(
        row['last_chapter'],
      ),
      isAdult:
          contentRating ==
                  'erotica' ||
              contentRating ==
                  'pornographic',
    );
  }

  int _intValue(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return double.tryParse(
          value?.toString() ??
              '',
        )?.toInt() ??
        0;
  }

  @override
  Future<Manga?>
      getMangaDetails(
    String sourceMangaId,
  ) async {
    return null;
  }

  @override
  Future<List<CanonicalChapter>>
      getChapters(
    String sourceMangaId,
  ) async {
    final parts =
        sourceMangaId.split('|');

    if (parts.length != 2) {
      return const [];
    }

    final hid =
        Uri.decodeComponent(
      parts[0],
    );

    final slug =
        Uri.decodeComponent(
      parts[1],
    );

    final chapters =
        <String,
            CanonicalChapter>{};

    const pageSize = 100;

    for (var page = 1;
        page <= 100;
        page++) {
      final response =
          await _apiClient
              .get<dynamic>(
        '/comic/$hid/chapters',
        queryParameters: {
          'lang': 'en',
          'limit': pageSize,
          'page': page,
        },
        options: Options(
          headers: const {
            'Referer':
                'https://comick.io/',
          },
        ),
      );

      final root =
          response.data;

      dynamic rawRows;

      if (root is Map) {
        rawRows =
            root['chapters'] ??
                root['data'];
      } else if (root is List) {
        rawRows = root;
      }

      if (rawRows is! List ||
          rawRows.isEmpty) {
        break;
      }

      for (final raw
          in rawRows
              .whereType<Map>()) {
        final row =
            Map<String, dynamic>
                .from(raw);

        final language =
            row['lang']
                ?.toString();

        if (language != null &&
            language.isNotEmpty &&
            language != 'en') {
          continue;
        }

        final chapterRaw =
            (row['chap'] ??
                    row['chapter'] ??
                    row[
                        'chapter_number'])
                ?.toString()
                .trim() ??
            '';

        /*
         * ComicK gives us an explicit structured
         * chapter field. Plain numbers are safe
         * here.
         */
        final number =
            double.tryParse(
                  chapterRaw,
                ) ??
                ChapterNumberParser
                    .parseVisibleLabel(
                  chapterRaw,
                  allowPlainNumber:
                      true,
                );

        if (number == null ||
            !number.isFinite ||
            number < 0 ||
            number > 20000) {
          continue;
        }

        final chapterHid =
            (row['hid'] ??
                    row[
                        'chapter_hid'] ??
                    row['id'])
                ?.toString();

        if (chapterHid == null ||
            chapterHid.isEmpty) {
          continue;
        }

        final key =
            ChapterNumberParser.label(
          number,
        );

        final existing =
            chapters[key];

        final published =
            DateTime.tryParse(
                  row['publish_at']
                          ?.toString() ??
                      row['created_at']
                          ?.toString() ??
                      '',
                ) ??
                DateTime
                    .fromMillisecondsSinceEpoch(
                  0,
                );

        final title =
            row['title']
                    ?.toString()
                    .trim() ??
                '';

        final copy =
            ChapterSourceCopy(
          sourceId: id,
          chapterId: [
            Uri.encodeComponent(
              slug,
            ),
            Uri.encodeComponent(
              chapterHid,
            ),
            Uri.encodeComponent(
              chapterRaw,
            ),
            'en',
          ].join('|'),
          reliability: .88,
          publishedAt:
              published,
          attribution:
              'ComicK',
        );

        chapters[key] =
            CanonicalChapter(
          id:
              'chapter:number:$key',
          number: number,
          title: title.isEmpty
              ? 'Chapter $key'
              : title,
          publishedAt:
              existing == null ||
                      published
                          .isBefore(
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

      if (rawRows.length <
          pageSize) {
        break;
      }
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
    final parts =
        sourceChapterId.split('|');

    if (parts.length != 4) {
      throw const SourceFailure(
        'ComicK chapter reference is invalid.',
        retryable: false,
      );
    }

    final slug =
        Uri.decodeComponent(
      parts[0],
    );

    final chapterHid =
        Uri.decodeComponent(
      parts[1],
    );

    final chapter =
        Uri.decodeComponent(
      parts[2],
    );

    final language =
        Uri.decodeComponent(
      parts[3],
    );

    final response =
        await _webClient
            .get<String>(
      '/comic/$slug/'
      '$chapterHid-chapter-$chapter-$language',
      options: Options(
        responseType:
            ResponseType.plain,
        headers: const {
          'Referer':
              'https://comick.io/',
        },
      ),
    );

    final document =
        html_parser.parse(
      response.data ?? '',
    );

    final urls =
        <String>[];

    final nextData =
        document
            .querySelector(
              'script#__NEXT_DATA__',
            )
            ?.text;

    if (nextData != null &&
        nextData.isNotEmpty) {
      try {
        _findImageKeys(
          jsonDecode(nextData),
          urls,
        );
      } catch (_) {}
    }

    if (urls.isEmpty) {
      for (final image
          in document
              .querySelectorAll(
        'img',
      )) {
        final raw =
            image.attributes[
                    'data-src'] ??
                image.attributes[
                    'src'];

        if (raw == null) {
          continue;
        }

        final url =
            _imageUrl(raw);

        if (url != null &&
            !urls.contains(url)) {
          urls.add(url);
        }
      }
    }

    if (urls.isEmpty ||
        urls.length > 600) {
      throw const SourceFailure(
        'ComicK chapter pages are unavailable.',
      );
    }

    return ChapterPages(
      chapterId:
          sourceChapterId,
      sourceId: id,
      urls: urls,
    );
  }

  void _findImageKeys(
    dynamic value,
    List<String> output,
  ) {
    if (value is Map) {
      for (final entry
          in value.entries) {
        if (entry.key ==
                'b2key' &&
            entry.value
                is String) {
          final url =
              _imageUrl(
            entry.value
                as String,
          );

          if (url != null &&
              !output
                  .contains(url)) {
            output.add(url);
          }
        }

        _findImageKeys(
          entry.value,
          output,
        );
      }
    } else if (value is List) {
      for (final child in value) {
        _findImageKeys(
          child,
          output,
        );
      }
    }
  }

  String? _imageUrl(
    String value,
  ) {
    final trimmed =
        value.trim();

    if (trimmed.isEmpty ||
        trimmed.contains('..')) {
      return null;
    }

    final String url;

    if (trimmed.startsWith(
      'https://',
    )) {
      url = trimmed;
    } else if (trimmed
        .startsWith('//')) {
      url = 'https:$trimmed';
    } else {
      url =
          'https://meo.comick.pictures/'
          '${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
    }

    final uri =
        Uri.tryParse(url);

    if (uri == null ||
        uri.scheme != 'https') {
      return null;
    }

    return url;
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
}