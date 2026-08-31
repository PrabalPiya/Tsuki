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

/// Isolated Mangakakalot chapter provider.
///
/// Parser failures return an empty result or a retryable source error and
/// cannot affect other sources.
class MangakakalotSource implements MangaSource {
  MangakakalotSource({Dio? client})
    : _client =
          client ?? createHttpClient(baseUrl: 'https://www.mangakakalot.gg');

  final Dio _client;
  final Map<String, ({DateTime savedAt, List<CanonicalChapter> chapters})>
  _chapterCache = {};
  static const _chapterTtl = Duration(minutes: 15);

  @override
  String get id => 'mangakakalot';

  @override
  String get displayName => 'Mangakakalot';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const {
    'storage.waitst.com',
    'imgs-2.2xstorage.com',
    'img-r1.2xstorage.com',
    'img-r2.2xstorage.com',
  };

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    final slug = _slugify(query);
    if (slug == null) return const [];
    try {
      final document = await _document(
        '/search/story/$slug',
        cancelToken: cancelToken,
      );
      final values = <String, Manga>{};
      for (final link in document.querySelectorAll('a[href*="/manga/"]')) {
        final uri = Uri.tryParse(link.attributes['href'] ?? '');
        final candidateSlug = _slugFromPath(uri?.path ?? '');
        if (candidateSlug == null) continue;
        final title = (link.attributes['title'] ?? link.text).trim();
        if (title.isEmpty || SourceMatching.similarity(query, title) < .72) {
          continue;
        }
        final card = _closestCard(link);
        final image = card?.querySelector('img') ?? link.querySelector('img');
        values[candidateSlug] = _manga(
          candidateSlug,
          title,
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
        );
      }
      if (values.isNotEmpty) return values.values.take(20).toList();

      // A number of Mangakakalot deployments resolve a normalized title
      // directly even when their search endpoint is unavailable.
      final direct = await _document('/manga/$slug', cancelToken: cancelToken);
      final title = direct.querySelector('h1')?.text.trim() ?? '';
      if (title.isEmpty || SourceMatching.similarity(query, title) < .88) {
        return const [];
      }
      final image = direct.querySelector(
        '.info-image img, .manga-info-pic img',
      );
      return [_manga(slug, title, image?.attributes['src'] ?? '')];
    } on DioException {
      rethrow;
    } catch (_) {
      return const [];
    }
  }

  Manga _manga(String slug, String title, String cover) => Manga(
    id: '$id:$slug',
    sourceMappings: {id: slug},
    title: title,
    coverUrl: _absoluteImage(cover),
    synopsis: '',
    status: MangaStatus.unknown,
    chapterCount: 0,
  );

  Future<String?> findConservativeMatch(Manga canonical) async {
    final direct = canonical.allSourceMappings[id];
    if (direct != null && _cleanSlug(direct) != null) return direct;
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
    final slug = _cleanSlug(sourceMangaId);
    if (slug == null) return null;
    final document = await _document('/manga/$slug');
    final title = SourceMetadataParser.text(document, const [
      '.manga-info-text h1',
      '.story-info-right h1',
      'main h1',
      'h1',
    ]);
    if (title.isEmpty) return null;
    final body = document.body?.text ?? '';
    final synopsis = SourceMetadataParser.text(document, const [
      '#panel-story-info-description',
      '.story-info-right-extent',
      '.description',
    ]).replaceFirst(RegExp(r'^description\s*:?\s*', caseSensitive: false), '');
    final cover = SourceMetadataParser.attribute(
      document,
      const [
        'meta[property="og:image"]',
        '.info-image img',
        '.manga-info-pic img',
      ],
      const ['content', 'data-src', 'src'],
    );
    final chapterCount = document
        .querySelectorAll('a[href^="/manga/$slug/chapter-"]')
        .length;
    return Manga(
      id: '$id:$slug',
      sourceMappings: {id: slug},
      title: title,
      aliases: SourceMetadataParser.labelledValues(body, const [
        'alternative',
        'alternative name',
        'other name',
      ]),
      coverUrl: _absoluteImage(cover),
      synopsis: synopsis,
      status: SourceMetadataParser.status(body),
      chapterCount: chapterCount,
      genres: SourceMetadataParser.labelledValues(body, const ['genres']),
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final slug = _cleanSlug(sourceMangaId);
    if (slug == null) return const [];
    final cached = _chapterCache[slug];
    if (cached != null &&
        DateTime.now().difference(cached.savedAt) < _chapterTtl) {
      return cached.chapters;
    }
    final response = await _client.get<Map<String, dynamic>>(
      '/api/manga/$slug/chapters',
      options: Options(
        headers: const {'Referer': 'https://www.mangakakalot.gg/'},
      ),
    );
    final data = response.data?['data'];
    final raw = data is Map ? data['chapters'] : null;
    if (raw is! List) return const [];
    final byKey = <String, CanonicalChapter>{};
    for (final value in raw.whereType<Map>()) {
      final chapter = Map<String, dynamic>.from(value);
      final chapterSlug = chapter['chapter_slug']?.toString() ?? '';
      if (!RegExp(r'^chapter-[a-z0-9.-]+$').hasMatch(chapterSlug)) continue;
      final number = ChapterNumberParser.parseVisibleLabel(
        chapter['chapter_num']?.toString() ??
            chapter['chapter_name']?.toString() ??
            chapterSlug.replaceAll('-', ' '),
        allowPlainNumber: true,
      );
      final rawTitle = chapter['chapter_name']?.toString().trim() ?? '';
      final key = number == null
          ? 'special:${SourceMatching.normalize(rawTitle.isEmpty ? chapterSlug : rawTitle)}'
          : 'number:${ChapterNumberParser.label(number)}';
      final published =
          DateTime.tryParse(chapter['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      byKey[key] = CanonicalChapter(
        id: 'chapter:$key',
        number: number,
        title: rawTitle.isEmpty
            ? (number == null
                  ? 'Special'
                  : 'Chapter ${ChapterNumberParser.label(number)}')
            : rawTitle,
        publishedAt: published,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: Uri.encodeComponent('$slug/$chapterSlug'),
            reliability: .7,
            publishedAt: published,
            attribution: displayName,
          ),
        ],
      );
    }
    final chapters = byKey.values.toList()
      ..sort((a, b) {
        if (a.number != null && b.number != null) {
          return a.number!.compareTo(b.number!);
        }
        if (a.number != null) return -1;
        if (b.number != null) return 1;
        return a.publishedAt.compareTo(b.publishedAt);
      });
    final result = List<CanonicalChapter>.unmodifiable(chapters);
    _chapterCache[slug] = (savedAt: DateTime.now(), chapters: result);
    return result;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final values = await getChapters(sourceMangaId);
    return values.lastOrNull;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final decoded = Uri.decodeComponent(sourceChapterId).trim();
    final match = RegExp(r'^([a-z0-9]+(?:-[a-z0-9]+)*)/(chapter-[a-z0-9.-]+)$')
        .firstMatch(decoded);
    if (match == null) {
      throw const SourceFailure('Chapter unavailable right now.');
    }
    final slug = match.group(1)!;
    final document = await _document('/manga/$slug/${match.group(2)}');
    final urls = <String>[];
    for (final image in document.querySelectorAll('img')) {
      final uri = Uri.tryParse(
        image.attributes['data-src'] ?? image.attributes['src'] ?? '',
      );
      if (uri == null ||
          uri.scheme != 'https' ||
          !allowedImageHosts.contains(uri.host) ||
          !uri.path.startsWith('/$slug/')) {
        continue;
      }
      if (!urls.contains(uri.toString())) urls.add(uri.toString());
    }
    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('Chapter pages unavailable right now.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  String? _slugFromPath(String path) {
    final match = RegExp(r'^/manga/([a-z0-9]+(?:-[a-z0-9]+)*)/?$')
        .firstMatch(path);
    return match?.group(1);
  }

  Element? _closestCard(Element element) {
    Element? current = element.parent;
    while (current != null) {
      final classes = current.classes;
      if (current.localName == 'li' ||
          classes.contains('story_item') ||
          classes.contains('list-truyen-item-wrap')) {
        return current;
      }
      current = current.parent;
    }
    return element.parent;
  }

  String? _slugify(String value) {
    final normalized = SourceMatching.normalize(value);
    return _cleanSlug(normalized.replaceAll(' ', '-'));
  }

  String? _cleanSlug(String value) {
    final cleaned = Uri.decodeComponent(value).trim().toLowerCase();
    return RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(cleaned)
        ? cleaned
        : null;
  }

  String _absoluteImage(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    return uri.hasScheme
        ? uri.toString()
        : Uri.parse('https://www.mangakakalot.gg').resolveUri(uri).toString();
  }

  Future<Document> _document(String path, {CancelToken? cancelToken}) async {
    final response = await _client.get<String>(
      path,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://www.mangakakalot.gg/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }
}
