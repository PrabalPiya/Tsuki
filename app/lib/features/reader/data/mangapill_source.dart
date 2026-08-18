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

class MangaPillSource
    implements MangaSource {
  MangaPillSource({
    Dio? client,
  }) : _client =
            client ??
            createHttpClient(
              baseUrl:
                  'https://mangapill.com',
            );

  final Dio _client;

  @override
  String get id => 'mangapill';

  @override
  String get displayName =>
      'MangaPill';

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
        'q': query,
      },
    );

    final results =
        <String, Manga>{};

    for (final anchor
        in document
            .querySelectorAll(
      'a[href*="/manga/"]',
    )) {
      final href =
          anchor.attributes[
              'href'];

      if (href == null) {
        continue;
      }

      final path =
          _path(href);

      if (path == null) {
        continue;
      }

      final parts =
          path.split('/');

      if (parts.length < 3 ||
          parts.first != 'manga') {
        continue;
      }

      final numericId =
          parts[1];

      final slug =
          parts[2];

      if (int.tryParse(
            numericId,
          ) ==
          null) {
        continue;
      }

      final image =
          anchor.querySelector(
        'img',
      );

      final title =
          (anchor.attributes[
                      'title'] ??
                  image?.attributes[
                      'alt'] ??
                  anchor.text)
              .replaceAll(
                RegExp(r'\s+'),
                ' ',
              )
              .trim();

      if (title.isEmpty) {
        continue;
      }

      final sourceId =
          '${Uri.encodeComponent(numericId)}|'
          '${Uri.encodeComponent(slug)}';

      results[sourceId] = Manga(
        id:
            'mangapill:$sourceId',
        title: title,
        coverUrl:
            _absolute(
          image?.attributes[
                  'data-src'] ??
              image?.attributes[
                  'src'] ??
              '',
        ),
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
            .take(4);

    final results =
        <String, Manga>{};

    for (final query in queries) {
      try {
        for (final manga
            in await search(query)) {
          results[manga.id] =
              manga;
        }
      } catch (_) {}
    }

    return SourceMatching.bestMatchId(
      canonical,
      results.values.toList(),
      sourcePrefix:
          'mangapill:',
      minimumScore: .86,
    );
  }

  @override
  Future<Manga?>
      getMangaDetails(
    String sourceMangaId,
  ) async {
    final parts =
        sourceMangaId.split('|');

    if (parts.length != 2) {
      return null;
    }

    final numericId =
        Uri.decodeComponent(
      parts[0],
    );

    final slug =
        Uri.decodeComponent(
      parts[1],
    );

    final document =
        await _document(
      '/manga/$numericId/$slug',
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
          'mangapill:$sourceMangaId',
      title: title,
      coverUrl: '',
      synopsis: '',
      status:
          MangaStatus.unknown,
      chapterCount:
          document
              .querySelectorAll(
                'a[href*="/chapters/"]',
              )
              .length,
    );
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

    final numericId =
        Uri.decodeComponent(
      parts[0],
    );

    final slug =
        Uri.decodeComponent(
      parts[1],
    );

    final document =
        await _document(
      '/manga/$numericId/$slug',
    );

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

      /*
       * Only visible text is parsed.
       * Never infer chapter numbers from href.
       */
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

      final copy =
          ChapterSourceCopy(
        sourceId: id,
        chapterId:
            Uri.encodeComponent(
          href,
        ),
        reliability: .67,
        publishedAt:
            DateTime
                .fromMillisecondsSinceEpoch(
          0,
        ),
        attribution:
            'MangaPill',
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
            existing?.publishedAt ??
                DateTime
                    .fromMillisecondsSinceEpoch(
                  0,
                ),
        sourceCopies: [
          ...?existing
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
      '/chapters/',
    )) {
      throw const SourceFailure(
        'Invalid MangaPill chapter.',
        retryable: false,
      );
    }

    final document =
        await _document(path);

    final urls =
        <String>[];

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

      final lower =
          raw.toLowerCase();

      if (lower.contains(
            'logo',
          ) ||
          lower.contains(
            'icon',
          ) ||
          lower.contains(
            'avatar',
          ) ||
          lower.contains(
            'cover',
          )) {
        continue;
      }

      final url =
          _absolute(raw);

      if (url.startsWith(
            'https://',
          ) &&
          !urls.contains(url)) {
        urls.add(url);
      }
    }

    if (urls.isEmpty ||
        urls.length > 600) {
      throw const SourceFailure(
        'MangaPill chapter unavailable.',
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
      ),
    );

    return html_parser.parse(
      response.data ?? '',
    );
  }

  String? _path(
    String value,
  ) {
    final uri =
        Uri.tryParse(value);

    return uri?.path
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
      return 'https://mangapill.com'
          '$trimmed';
    }

    return 'https://mangapill.com/'
        '$trimmed';
  }
}