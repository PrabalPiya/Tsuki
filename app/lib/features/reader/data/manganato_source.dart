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

class ManganatoSource implements MangaSource {
  ManganatoSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://www.manganato.gg');

  final Dio _client;

  @override
  String get id => 'manganato';

  @override
  String get displayName => 'Manganato';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
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
  Future<List<Manga>> search(String query) async {
    final slug = _slugify(query);
    if (slug == null) return const [];
    try {
      final document = await _document('/manga/$slug');
      final title = document.querySelector('h1')?.text.trim() ?? '';
      if (title.isEmpty || SourceMatching.similarity(query, title) < .88) {
        return const [];
      }
      final image = document.querySelector(
        'img[alt="${_escapeAttribute(title)}"], .info-image img, .manga-info-pic img',
      );
      return [
        Manga(
          id: '$id:$slug',
          title: title,
          coverUrl: _absoluteImage(
            image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
          ),
          synopsis: '',
          status: MangaStatus.unknown,
          chapterCount: 0,
        ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final canonicalNames = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(SourceMatching.normalize).where((value) => value.isNotEmpty).toSet();
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      final candidates = await search(query);
      for (final candidate in candidates) {
        if (canonicalNames.contains(
          SourceMatching.normalize(candidate.title),
        )) {
          return candidate.id.replaceFirst('$id:', '');
        }
      }
      final match = SourceMatching.bestMatchId(
        canonical,
        candidates,
        sourcePrefix: '$id:',
        minimumScore: .9,
        ambiguityMargin: .04,
      );
      if (match != null) return match;
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async => null;

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final slug = _cleanSlug(sourceMangaId);
    if (slug == null) return const [];
    final response = await _client.get<Map<String, dynamic>>(
      '/api/manga/$slug/chapters',
      options: Options(headers: const {'Referer': 'https://www.manganato.gg/'}),
    );
    final root = response.data;
    final data = root?['data'];
    final rawChapters = data is Map ? data['chapters'] : null;
    if (rawChapters is! List) return const [];

    final chapters = <String, CanonicalChapter>{};
    for (final raw in rawChapters.whereType<Map>()) {
      final chapter = Map<String, dynamic>.from(raw);
      final chapterSlug = chapter['chapter_slug']?.toString() ?? '';
      if (!RegExp(r'^chapter-\d+(?:\.\d+)?$').hasMatch(chapterSlug)) continue;
      final number = ChapterNumberParser.parseVisibleLabel(
        chapter['chapter_num']?.toString() ??
            chapter['chapter_name']?.toString() ??
            '',
        allowPlainNumber: true,
      );
      if (number == null) continue;
      final publishedAt =
          DateTime.tryParse(chapter['updated_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final label = ChapterNumberParser.label(number);
      chapters[label] = CanonicalChapter(
        id: 'chapter:number:$label',
        number: number,
        title: chapter['chapter_name']?.toString() ?? 'Chapter $label',
        publishedAt: publishedAt,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: Uri.encodeComponent('$slug/$chapterSlug'),
            reliability: .72,
            publishedAt: publishedAt,
            attribution: displayName,
          ),
        ],
      );
    }

    final values = chapters.values.toList()
      ..sort((left, right) => (left.number ?? 0).compareTo(right.number ?? 0));
    return values;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    return chapters.isEmpty ? null : chapters.last;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final value = Uri.decodeComponent(sourceChapterId).trim();
    final match = RegExp(
      r'^([a-z0-9]+(?:-[a-z0-9]+)*)/(chapter-\d+(?:\.\d+)?)$',
    ).firstMatch(value);
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
      final pageUrl = uri.toString();
      if (!urls.contains(pageUrl)) urls.add(pageUrl);
    }
    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('Chapter pages unavailable right now.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  String? _slugify(String value) {
    final normalized = SourceMatching.normalize(value);
    if (normalized.length < 2) return null;
    return _cleanSlug(normalized.replaceAll(' ', '-'));
  }

  String? _cleanSlug(String value) {
    final cleaned = Uri.decodeComponent(value).trim().toLowerCase();
    return RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(cleaned)
        ? cleaned
        : null;
  }

  String _escapeAttribute(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

  String _absoluteImage(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    return uri.hasScheme
        ? uri.toString()
        : Uri.parse('https://www.manganato.gg').resolveUri(uri).toString();
  }

  Future<Document> _document(String path) async {
    final response = await _client.get<String>(
      path,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://www.manganato.gg/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }
}
