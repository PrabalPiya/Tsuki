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

/// Isolated MangaKatana chapter and reader fallback.
class MangaKatanaSource implements MangaSource {
  MangaKatanaSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://mangakatana.com');

  final Dio _client;
  final Map<String, ({DateTime savedAt, List<CanonicalChapter> chapters})>
  _chapterCache = {};
  static const _chapterTtl = Duration(minutes: 15);

  @override
  String get id => 'mangakatana';

  @override
  String get displayName => 'MangaKatana';

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
    'i1.mangakatana.com',
    'i2.mangakatana.com',
    'i3.mangakatana.com',
    'i4.mangakatana.com',
    'i5.mangakatana.com',
    'i6.mangakatana.com',
    'i7.mangakatana.com',
    'i8.mangakatana.com',
    'i9.mangakatana.com',
  };

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    final cleaned = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length < 3) return const [];
    try {
      final response = await _client.post<String>(
        '/',
        cancelToken: cancelToken,
        data: {'s': cleaned, 'search_by': 'm_name'},
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          headers: const {'Referer': 'https://mangakatana.com/'},
        ),
      );
      final document = html_parser.parse(response.data ?? '');
      final results = <String, Manga>{};
      for (final link in document.querySelectorAll(
        '.title a[href*="/manga/"], a[href*="/manga/"]',
      )) {
        final sourceId = _mangaId(link.attributes['href']);
        if (sourceId == null || results.containsKey(sourceId)) continue;
        final card = _closestCard(link);
        final title = (link.attributes['title'] ?? link.text)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (title.isEmpty || SourceMatching.similarity(cleaned, title) < .65) {
          continue;
        }
        final image = card?.querySelector('img') ?? link.querySelector('img');
        results[sourceId] = Manga(
          id: '$id:$sourceId',
          sourceMappings: {id: sourceId},
          title: title,
          coverUrl: _absoluteImage(
            image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
          ),
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
    final direct = _normalizeMangaId(canonical.allSourceMappings[id]);
    if (direct != null) return direct;
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
    final normalizedId = _normalizeMangaId(sourceMangaId);
    if (normalizedId == null) return null;
    final document = await _document('/manga/$normalizedId');
    final title = SourceMetadataParser.text(document, const [
      '.info .heading',
      '.info h1',
      '.manga-info h1',
      'main h1',
      'h1',
    ]);
    if (title.isEmpty) return null;
    final body = document.body?.text ?? '';
    final cover = SourceMetadataParser.attribute(
      document,
      const [
        'meta[property="og:image"]',
        '.cover img',
        '.info img',
        '.manga-info img',
      ],
      const ['content', 'data-src', 'src'],
    );
    return Manga(
      id: '$id:$normalizedId',
      sourceMappings: {id: normalizedId},
      title: title,
      aliases: SourceMetadataParser.labelledValues(body, const [
        'alternative',
        'alternative name',
        'other name',
      ]),
      coverUrl: _absoluteImage(cover),
      synopsis: SourceMetadataParser.text(document, const [
        '.summary',
        '.description',
        '.manga-summary',
      ]),
      status: SourceMetadataParser.status(body),
      chapterCount: document.querySelectorAll('.chapters a[href]').length,
      genres: SourceMetadataParser.labelledValues(body, const ['genres']),
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final normalizedId = _normalizeMangaId(sourceMangaId);
    if (normalizedId == null) return const [];
    final cached = _chapterCache[normalizedId];
    if (cached != null &&
        DateTime.now().difference(cached.savedAt) < _chapterTtl) {
      return cached.chapters;
    }
    final document = await _document('/manga/$normalizedId');
    final chapters = <String, CanonicalChapter>{};
    for (final row in document.querySelectorAll('.chapters tr')) {
      final anchor = row.querySelector('a[href*="/manga/"]');
      final chapterId = _chapterId(anchor?.attributes['href']);
      if (chapterId == null || !chapterId.startsWith('$normalizedId/')) {
        continue;
      }
      final rawTitle = anchor!.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final number = ChapterNumberParser.parseVisibleLabel(rawTitle);
      if (number == null) continue;
      final label = ChapterNumberParser.label(number);
      final published = _parseDate(
        row.querySelector('.update_time')?.text.trim() ?? '',
      );
      chapters[label] = CanonicalChapter(
        id: 'chapter:number:$label',
        number: number,
        title: rawTitle.isEmpty ? 'Chapter $label' : rawTitle,
        publishedAt: published,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: Uri.encodeComponent(chapterId),
            reliability: .76,
            publishedAt: published,
            attribution: displayName,
          ),
        ],
      );
    }
    final values = chapters.values.toList()
      ..sort((left, right) => left.number!.compareTo(right.number!));
    final result = List<CanonicalChapter>.unmodifiable(values);
    _chapterCache[normalizedId] = (savedAt: DateTime.now(), chapters: result);
    return result;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    return chapters.lastOrNull;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final decoded = Uri.decodeComponent(sourceChapterId).trim().toLowerCase();
    if (_chapterId('/manga/$decoded') != decoded) {
      throw const SourceFailure('Chapter unavailable right now.');
    }
    final document = await _document('/manga/$decoded');
    final urls = <String>[];
    final imagePattern = RegExp(
      r'''https://i[1-9]\.mangakatana\.com/token/[^'"\s<>]+\.(?:avif|jpe?g|png|webp)''',
      caseSensitive: false,
    );
    for (final script in document.querySelectorAll('script')) {
      for (final match in imagePattern.allMatches(script.text)) {
        final uri = Uri.tryParse(match.group(0)!);
        if (uri == null ||
            uri.scheme != 'https' ||
            !allowedImageHosts.contains(uri.host) ||
            !uri.path.startsWith('/token/')) {
          continue;
        }
        final value = uri.toString();
        if (!urls.contains(value)) urls.add(value);
      }
    }
    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('Chapter pages unavailable right now.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  String? _mangaId(String? raw) {
    final uri = Uri.tryParse(raw ?? '');
    if (uri == null ||
        (uri.hasAuthority &&
            uri.host != 'mangakatana.com' &&
            uri.host != 'www.mangakatana.com')) {
      return null;
    }
    final path = uri.path.toLowerCase();
    final match = RegExp(r'^/manga/([^/?#\s]+\.\d+)/?$').firstMatch(path);
    return match?.group(1);
  }

  String? _chapterId(String? raw) {
    final uri = Uri.tryParse(raw ?? '');
    if (uri == null ||
        (uri.hasAuthority &&
            uri.host != 'mangakatana.com' &&
            uri.host != 'www.mangakatana.com')) {
      return null;
    }
    final path = uri.path.toLowerCase();
    final match = RegExp(r'^/manga/([^/?#\s]+\.\d+/[a-z0-9.-]+)/?$')
        .firstMatch(path);
    return match?.group(1);
  }

  String? _normalizeMangaId(String? value) {
    if (value == null) return null;
    return _mangaId('/manga/${value.trim().toLowerCase()}');
  }

  DateTime _parseDate(String raw) {
    final match = RegExp(r'^(\w{3})-(\d{1,2})-(\d{4})$').firstMatch(raw);
    if (match == null) return DateTime.fromMillisecondsSinceEpoch(0);
    const months = <String, int>{
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final month = months[match.group(1)];
    final day = int.tryParse(match.group(2)!);
    final year = int.tryParse(match.group(3)!);
    return month == null || day == null || year == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.utc(year, month, day);
  }

  Element? _closestCard(Element element) {
    Element? current = element.parent;
    while (current != null) {
      if (current.classes.contains('item') || current.localName == 'li') {
        return current;
      }
      current = current.parent;
    }
    return element.parent;
  }

  String _absoluteImage(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    return uri.hasScheme
        ? uri.toString()
        : Uri.parse('https://mangakatana.com').resolveUri(uri).toString();
  }

  Future<Document> _document(String path) async {
    final response = await _client.get<String>(
      path,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://mangakatana.com/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }
}
