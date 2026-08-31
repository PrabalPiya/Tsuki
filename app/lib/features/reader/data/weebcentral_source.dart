import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_metadata_parser.dart';
import 'source_matching.dart';

/// Public Weeb Central reader fallback.
class WeebCentralSource implements MangaSource {
  WeebCentralSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://weebcentral.com');

  final Dio _client;

  @override
  String get id => 'weebcentral';

  @override
  String get displayName => 'Weeb Central';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const {'scans-hot.planeptune.us'};

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    final cleaned = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length < 2) return const [];
    try {
      final response = await _client.post<String>(
        '/search/simple',
        cancelToken: cancelToken,
        queryParameters: const {'location': 'main'},
        data: {'text': cleaned},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
        ),
      );
      final document = html_parser.parse(response.data ?? '');
      final results = <String, Manga>{};
      for (final anchor in document.querySelectorAll('a[href*="/series/"]')) {
        final sourceId = _seriesId(anchor.attributes['href']);
        if (sourceId == null) continue;
        final image = anchor.querySelector('img');
        final title = (image?.attributes['alt'] ?? anchor.text)
            .replaceFirst(RegExp(r'\s+cover$', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (title.isEmpty) continue;
        results[sourceId] = Manga(
          id: '$id:$sourceId',
          sourceMappings: {id: sourceId},
          title: title,
          coverUrl: _absoluteImage(image?.attributes['src'] ?? ''),
          synopsis: '',
          status: MangaStatus.unknown,
          chapterCount: 0,
        );
      }
      return results.values.take(20).toList(growable: false);
    } on DioException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final direct = canonical.allSourceMappings[id];
    if (_validId(direct)) return direct;
    final expected = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(SourceMatching.normalize).where((value) => value.isNotEmpty).toSet();
    final candidates = <Manga>[];
    for (final query in SourceMatching.searchQueries(canonical, maximum: 8)) {
      candidates.addAll(await search(query));
      for (final candidate in candidates) {
        if (expected.contains(SourceMatching.normalize(candidate.title))) {
          return candidate.allSourceMappings[id];
        }
      }
    }
    return SourceMatching.bestMatchId(
      canonical,
      candidates,
      sourcePrefix: '$id:',
      minimumScore: .92,
      ambiguityMargin: .06,
    );
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    if (!_validId(sourceMangaId)) return null;
    final document = await _document('/series/$sourceMangaId');
    final title = SourceMetadataParser.text(document, const [
      'main h1',
      'article h1',
      'h1',
    ]);
    if (title.isEmpty) return null;
    final body = document.body?.text ?? '';
    final cover = SourceMetadataParser.attribute(
      document,
      const ['meta[property="og:image"]', 'main img', 'article img'],
      const ['content', 'data-src', 'src'],
    );
    return Manga(
      id: '$id:$sourceMangaId',
      sourceMappings: {id: sourceMangaId},
      title: title,
      aliases: SourceMetadataParser.labelledValues(body, const [
        'alternative',
        'alternative titles',
        'other names',
      ]),
      coverUrl: _absoluteImage(cover),
      synopsis: SourceMetadataParser.text(document, const [
        '[data-testid="description"]',
        '.description',
        'main article p',
      ]),
      status: SourceMetadataParser.status(body),
      chapterCount: 0,
      genres: SourceMetadataParser.labelledValues(body, const ['genres']),
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    if (!_validId(sourceMangaId)) return const [];
    final document = await _document(
      '/series/$sourceMangaId/full-chapter-list',
    );
    final chapters = <String, CanonicalChapter>{};
    for (final anchor in document.querySelectorAll('a[href*="/chapters/"]')) {
      final chapterId = _chapterId(anchor.attributes['href']);
      if (chapterId == null) continue;
      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final number = ChapterNumberParser.parseVisibleLabel(text);
      if (number == null) continue;
      final label = ChapterNumberParser.label(number);
      final published = _publishedAt(text);
      chapters[label] = CanonicalChapter(
        id: 'chapter:number:$label',
        number: number,
        title: 'Chapter $label',
        publishedAt: published,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: chapterId,
            reliability: .88,
            publishedAt: published,
            attribution: displayName,
          ),
        ],
      );
    }
    final values = chapters.values.toList()
      ..sort((left, right) => left.number!.compareTo(right.number!));
    return List<CanonicalChapter>.unmodifiable(values);
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    return chapters.lastOrNull;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    if (!_validId(sourceChapterId)) {
      throw const SourceFailure('Chapter unavailable right now.');
    }
    final document = await _document(
      '/chapters/$sourceChapterId/images',
      queryParameters: const {'is_prev': 'False'},
    );
    final urls = <String>[];
    for (final image in document.querySelectorAll('img')) {
      final uri = Uri.tryParse(
        image.attributes['data-src'] ?? image.attributes['src'] ?? '',
      );
      if (uri == null ||
          uri.scheme != 'https' ||
          !_allowedPageHost(uri.host) ||
          !RegExp(
            r'\.(?:avif|jpe?g|png|webp)$',
            caseSensitive: false,
          ).hasMatch(uri.path)) {
        continue;
      }
      final value = uri.toString();
      if (!urls.contains(value)) urls.add(value);
    }
    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('Chapter pages unavailable right now.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  bool _allowedPageHost(String host) =>
      host == 'planeptune.us' || host.endsWith('.planeptune.us');

  bool _validId(String? value) =>
      value != null && RegExp(r'^[0-9A-Z]{26}$').hasMatch(value);

  String? _seriesId(String? raw) {
    final path = Uri.tryParse(raw ?? '')?.path ?? '';
    return RegExp(r'^/series/([0-9A-Z]{26})(?:/|$)').firstMatch(path)?.group(1);
  }

  String? _chapterId(String? raw) {
    final path = Uri.tryParse(raw ?? '')?.path ?? '';
    return RegExp(r'^/chapters/([0-9A-Z]{26})/?$').firstMatch(path)?.group(1);
  }

  DateTime _publishedAt(String text) {
    final raw = RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z')
        .firstMatch(text)
        ?.group(0);
    return DateTime.tryParse(raw ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _absoluteImage(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    return uri.hasScheme
        ? uri.toString()
        : Uri.parse('https://weebcentral.com').resolveUri(uri).toString();
  }

  Future<Document> _document(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _client.get<String>(
      path,
      queryParameters: queryParameters,
      options: Options(responseType: ResponseType.plain),
    );
    return html_parser.parse(response.data ?? '');
  }
}
