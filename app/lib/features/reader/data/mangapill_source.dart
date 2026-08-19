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

class MangaPillSource implements MangaSource {
  MangaPillSource({Dio? client})
      : _client = client ?? createHttpClient(baseUrl: 'https://mangapill.com');

  final Dio _client;

  @override
  String get id => 'mangapill';

  @override
  String get displayName => 'MangaPill';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
        search: true,
        details: true,
        chapters: true,
        pages: true,
        updates: true,
      );

  @override
  Set<String> get allowedImageHosts => const {};

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const [];

    final document = await _document(
      '/search',
      queryParameters: {'q': cleaned, 'page': 1},
    );

    final results = <String, Manga>{};
    final cards = document.querySelectorAll('.grid > div:not([class])');

    for (final card in cards) {
      final anchor = card.querySelector('a[href^="/manga/"]');
      if (anchor == null) continue;
      final href = anchor.attributes['href'];
      if (href == null) continue;

      final sourceId = _sourceIdFromMangaHref(href);
      if (sourceId == null) continue;

      final title = (card.querySelector('div.line-clamp-2')?.text ??
              anchor.attributes['title'] ??
              anchor.querySelector('img')?.attributes['alt'] ??
              anchor.text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (title.isEmpty) continue;

      final image = card.querySelector('img') ?? anchor.querySelector('img');
      results[sourceId] = Manga(
        id: 'mangapill:$sourceId',
        title: title,
        coverUrl: _absolute(
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
        ),
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
      );
    }

    // Compatibility fallback if the card structure changes slightly.
    if (results.isEmpty) {
      for (final anchor in document.querySelectorAll('a[href^="/manga/"]')) {
        final href = anchor.attributes['href'];
        if (href == null) continue;
        final sourceId = _sourceIdFromMangaHref(href);
        if (sourceId == null) continue;
        final title = (anchor.querySelector('img')?.attributes['alt'] ??
                anchor.attributes['title'] ??
                anchor.text)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (title.isEmpty) continue;
        results[sourceId] = Manga(
          id: 'mangapill:$sourceId',
          title: title,
          coverUrl: _absolute(
            anchor.querySelector('img')?.attributes['data-src'] ??
                anchor.querySelector('img')?.attributes['src'] ??
                '',
          ),
          synopsis: '',
          status: MangaStatus.unknown,
          chapterCount: 0,
        );
      }
    }

    return results.values.toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final canonicalNames = <String>{canonical.title, ...canonical.aliases}
        .map(SourceMatching.normalize)
        .where((value) => value.isNotEmpty)
        .toSet();

    final queries = <String>{canonical.title, ...canonical.aliases}
        .map((value) => value.trim())
        .where((value) => value.length >= 2)
        .take(8);

    for (final query in queries) {
      try {
        final candidates = await search(query);
        if (candidates.isEmpty) continue;

        for (final candidate in candidates) {
          if (canonicalNames.contains(SourceMatching.normalize(candidate.title))) {
            return candidate.id.replaceFirst('mangapill:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'mangapill:',
          minimumScore: .84,
          ambiguityMargin: .03,
        );
        if (match != null) return match;
      } catch (_) {
        // Try another alias/source.
      }
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = _mangaPath(sourceMangaId);
    if (path == null) return null;
    final document = await _document(path);
    final title = document.querySelector('h1')?.text.trim() ?? '';
    if (title.isEmpty) return null;

    final count = document.querySelectorAll('#chapters > div > a').length;
    return Manga(
      id: 'mangapill:$sourceMangaId',
      title: title,
      coverUrl: _absolute(
        document.querySelector('div.container img')?.attributes['data-src'] ??
            '',
      ),
      synopsis: document
              .querySelector('div.container p')
              ?.text
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim() ??
          '',
      status: MangaStatus.unknown,
      chapterCount: count,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = _mangaPath(sourceMangaId);
    if (path == null) return const [];

    final document = await _document(path);
    final chapters = <String, CanonicalChapter>{};

    // Current maintained MangaPill source uses this exact chapter container.
    var anchors = document.querySelectorAll('#chapters > div > a');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('#chapters a[href*="/chapters/"]');
    }

    for (final anchor in anchors) {
      final href = anchor.attributes['href'];
      if (href == null || !href.contains('/chapters/')) continue;

      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final number = ChapterNumberParser.parseVisibleLabel(
        text,
        allowPlainNumber: true,
      );
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }

      final key = number == null
          ? _specialKey(text, href)
          : ChapterNumberParser.label(number);
      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: Uri.encodeComponent(_absolutePath(href)),
        reliability: .72,
        publishedAt: DateTime.fromMillisecondsSinceEpoch(0),
        attribution: 'MangaPill',
      );

      final existing = chapters[key];
      chapters[key] = CanonicalChapter(
        id: number == null ? 'chapter:special:$key' : 'chapter:number:$key',
        number: number,
        title: text.isEmpty
            ? (number == null ? 'Special' : 'Chapter $key')
            : text,
        publishedAt:
            existing?.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
        sourceCopies: [...?existing?.sourceCopies, copy],
      );
    }

    final values = chapters.values.toList()
      ..sort((a, b) {
        final left = a.number;
        final right = b.number;
        if (left != null && right != null) return left.compareTo(right);
        if (left != null) return -1;
        if (right != null) return 1;
        return a.title.compareTo(b.title);
      });
    return values;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (!path.startsWith('/chapters/')) {
      throw const SourceFailure(
        'Invalid MangaPill chapter.',
        retryable: false,
      );
    }

    final document = await _document(path);
    final urls = <String>[];

    // Current MangaPill reader places actual pages in <picture><img data-src>.
    var images = document.querySelectorAll('picture img');
    if (images.isEmpty) images = document.querySelectorAll('img[data-src]');

    for (final image in images) {
      final raw = image.attributes['data-src'] ?? image.attributes['src'];
      if (raw == null || raw.trim().isEmpty) continue;
      final url = _absolute(raw);
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        continue;
      }
      if (!urls.contains(url)) urls.add(url);
    }

    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('MangaPill chapter unavailable.');
    }

    return ChapterPages(
      chapterId: sourceChapterId,
      sourceId: id,
      urls: urls,
    );
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final values = await getChapters(sourceMangaId);
    return values.isEmpty ? null : values.last;
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
        headers: const {'Referer': 'https://mangapill.com/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }

  String _specialKey(String label, String href) {
    final normalized = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (normalized.isNotEmpty) return normalized;
    final parts = _absolutePath(href)
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
    return parts.isEmpty ? 'special' : parts.last;
  }

  String? _sourceIdFromMangaHref(String value) {
    final path = _absolutePath(value).replaceFirst(RegExp(r'^/+'), '');
    final parts = path.split('/');
    if (parts.length < 3 || parts[0] != 'manga') return null;
    if (int.tryParse(parts[1]) == null || parts[2].trim().isEmpty) return null;
    return '${Uri.encodeComponent(parts[1])}|${Uri.encodeComponent(parts[2])}';
  }

  String? _mangaPath(String sourceMangaId) {
    final parts = sourceMangaId.split('|');
    if (parts.length != 2) return null;
    final numericId = Uri.decodeComponent(parts[0]);
    final slug = Uri.decodeComponent(parts[1]);
    if (int.tryParse(numericId) == null || slug.isEmpty) return null;
    return '/manga/$numericId/$slug';
  }

  String _absolutePath(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value.startsWith('/') ? value : '/$value';
    final path = uri.path;
    return path.startsWith('/') ? path : '/$path';
  }

  String _absolute(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('https://')) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('/')) return 'https://mangapill.com$trimmed';
    return 'https://mangapill.com/$trimmed';
  }
}
