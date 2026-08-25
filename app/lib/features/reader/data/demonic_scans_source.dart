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

class DemonicScansSource implements MangaSource {
  DemonicScansSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://demonicscans.org');

  final Dio _client;

  @override
  String get id => 'demonicscans';

  @override
  String get displayName => 'Demonic Scans';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const {'cdn.demoniclibs.com'};

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const [];

    final document = await _document(
      '/search.php',
      queryParameters: {'manga': cleaned},
    );
    final results = <String, Manga>{};
    for (final anchor in document.querySelectorAll('a[href^="/manga/"]')) {
      final sourceId = _sourceIdForPath(anchor.attributes['href']);
      if (sourceId == null) continue;
      final image = anchor.querySelector('img');
      final title =
          (anchor.querySelector('.seach-right div')?.text ??
                  anchor.attributes['title'] ??
                  image?.attributes['alt'] ??
                  '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      if (title.isEmpty) continue;
      results[sourceId] = Manga(
        id: '$id:$sourceId',
        title: title,
        coverUrl: _absoluteImage(image?.attributes['src'] ?? ''),
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
      );
    }
    return results.values.toList(growable: false);
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
      try {
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
          minimumScore: .88,
          ambiguityMargin: .04,
        );
        if (match != null) return match;
      } catch (_) {
        // Try another official title/alias.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async => null;

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = _seriesPathFromId(sourceMangaId);
    if (path == null) return const [];
    final document = await _document(path);
    final chapters = <String, CanonicalChapter>{};

    for (final anchor in document.querySelectorAll('a.chplinks')) {
      final chapterId = _chapterId(anchor.attributes['href']);
      if (chapterId == null) continue;
      final query = Uri.splitQueryString(Uri.decodeComponent(chapterId));
      final number = ChapterNumberParser.parseVisibleLabel(
        query['chapter'] ?? '',
        allowPlainNumber: true,
      );
      if (number == null) continue;
      final publishedAt = _publishedAt(anchor);
      final label = ChapterNumberParser.label(number);
      chapters[label] = CanonicalChapter(
        id: 'chapter:number:$label',
        number: number,
        title: 'Chapter $label',
        publishedAt: publishedAt,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: chapterId,
            reliability: .86,
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
    final query = Uri.decodeComponent(sourceChapterId).trim();
    if (!RegExp(r'^manga=\d+&chapter=\d+(?:\.\d+)?$').hasMatch(query)) {
      throw const SourceFailure('Chapter unavailable right now.');
    }
    final document = await _document(
      '/chaptered.php',
      queryParameters: Uri.splitQueryString(query),
    );
    final urls = <String>[];
    for (final image in document.querySelectorAll('img.imgholder')) {
      final uri = Uri.tryParse(image.attributes['src'] ?? '');
      if (uri == null ||
          uri.scheme != 'https' ||
          !allowedImageHosts.contains(uri.host)) {
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

  String? _sourceIdForPath(String? raw) {
    final uri = Uri.tryParse(raw ?? '');
    if (uri == null || (uri.hasAuthority && uri.host != 'demonicscans.org')) {
      return null;
    }
    final path = uri.path;
    if (!RegExp(r'^/manga/[^/?#]+$').hasMatch(path)) return null;
    return Uri.encodeComponent(path);
  }

  String? _seriesPathFromId(String raw) {
    try {
      final path = Uri.decodeComponent(raw).trim();
      return RegExp(r'^/manga/[^/?#]+$').hasMatch(path) ? path : null;
    } on FormatException {
      return null;
    }
  }

  String? _chapterId(String? raw) {
    final uri = Uri.tryParse(raw ?? '');
    final isChapterPath =
        uri?.path.endsWith('/chaptered.php') == true ||
        uri?.path == 'chaptered.php';
    if (uri == null ||
        (uri.hasAuthority && uri.host != 'demonicscans.org') ||
        !isChapterPath) {
      return null;
    }
    final mangaId = uri.queryParameters['manga'];
    final chapter = uri.queryParameters['chapter'];
    if (mangaId == null ||
        chapter == null ||
        !RegExp(r'^\d+$').hasMatch(mangaId) ||
        !RegExp(r'^\d+(?:\.\d+)?$').hasMatch(chapter)) {
      return null;
    }
    return Uri.encodeComponent('manga=$mangaId&chapter=$chapter');
  }

  DateTime _publishedAt(Element anchor) {
    final match = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b')
        .firstMatch(anchor.text);
    return match == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.tryParse(match.group(0)!) ??
              DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _absoluteImage(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return '';
    return uri.hasScheme
        ? uri.toString()
        : Uri.parse('https://demonicscans.org').resolveUri(uri).toString();
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
        headers: const {'Referer': 'https://demonicscans.org/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }
}
