import 'dart:convert';

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

class AsuraSource implements MangaSource {
  AsuraSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://asurascans.com');

  static const _apiSeries = 'https://api.asurascans.com/api/series';

  final Dio _client;

  @override
  String get id => 'asura';

  @override
  String get displayName => 'Asura';

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
    final cleaned = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length < 2) return const [];

    // Current Asura exposes a structured public series endpoint. Using it is
    // far faster and less fragile than crawling every /browse page.
    final response = await _client.get<dynamic>(
      _apiSeries,
      queryParameters: {'offset': 0, 'limit': 20, 'search': cleaned},
      options: Options(headers: const {'Referer': 'https://asurascans.com/'}),
    );

    final root = response.data;
    if (root is! Map) return const [];
    final rawData = root['data'];
    if (rawData is! List) return const [];

    final result = <Manga>[];
    for (final raw in rawData.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final title = row['title']?.toString().trim() ?? '';
      final stableSlug = row['slug']?.toString().trim() ?? '';
      final publicUrl =
          row['public_url']?.toString().trim() ??
          row['publicUrl']?.toString().trim() ??
          '';
      final randomSlug = _publicSlug(publicUrl) ?? stableSlug;
      if (title.isEmpty || randomSlug.isEmpty) continue;

      final path = 'comics/$randomSlug';
      final cover =
          row['cover']?.toString() ?? row['coverUrl']?.toString() ?? '';
      result.add(
        Manga(
          id: 'asura:${Uri.encodeComponent(path)}',
          title: title,
          coverUrl: _absolute(cover),
          synopsis: '',
          status: MangaStatus.unknown,
          chapterCount: 0,
        ),
      );
    }
    return result;
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      try {
        final candidates = await search(query);
        if (candidates.isEmpty) continue;

        final exactNames = <String>{
          canonical.title,
          ...canonical.aliases,
        }.map(SourceMatching.normalize).toSet();
        for (final candidate in candidates) {
          if (exactNames.contains(SourceMatching.normalize(candidate.title))) {
            return candidate.id.replaceFirst('asura:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'asura:',
          minimumScore: .84,
          ambiguityMargin: .03,
        );
        if (match != null) return match;
      } catch (_) {
        // Other aliases and sources remain available.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (!path.startsWith('comics/')) return null;

    final document = await _documentWithRedirectFallback(path);
    final astro = _findAstroObject(document, const ['title', 'description']);

    final title =
        astro?['title']?.toString().trim() ??
        document
            .querySelector('h1')
            ?.text
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim() ??
        '';
    if (title.isEmpty) return null;

    final statusRaw = astro?['status']?.toString().toLowerCase();
    return Manga(
      id: 'asura:$sourceMangaId',
      title: title,
      aliases: _aliasesFromAstro(astro),
      coverUrl: _absolute(
        astro?['coverUrl']?.toString() ?? _findCover(document),
      ),
      synopsis: _plainText(
        astro?['description']?.toString() ?? _longestParagraph(document),
      ),
      status: switch (statusRaw) {
        'ongoing' => MangaStatus.ongoing,
        'completed' => MangaStatus.completed,
        'hiatus' => MangaStatus.hiatus,
        'dropped' || 'axed' => MangaStatus.cancelled,
        _ => MangaStatus.unknown,
      },
      chapterCount: 0,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final requestedPath = Uri.decodeComponent(sourceMangaId);
    if (!requestedPath.startsWith('comics/')) return const [];

    final document = await _documentWithRedirectFallback(requestedPath);

    // Asura periodically rotates a random suffix in its public manga slug. The
    // page itself exposes the current publicUrl, so chapter page references must
    // use that current slug rather than a possibly stale persisted mapping.
    final urlAstro = _findAstroObject(document, const ['publicUrl']);
    final currentSlug = _publicSlug(urlAstro?['publicUrl']?.toString() ?? '');
    final currentPath = currentSlug == null
        ? requestedPath
        : 'comics/$currentSlug';

    // Current Asura embeds the complete chapter list as an Astro prop. Prefer
    // that structured data, then retain DOM parsing as a compatibility fallback.
    final astroRoot = _findAstroObject(document, const ['chapters']);
    final rawChapters = astroRoot?['chapters'];
    if (rawChapters is List) {
      final values = _chaptersFromAstro(rawChapters, currentPath);
      if (values.isNotEmpty) return values;
    }

    return _chaptersFromDom(document, currentPath);
  }

  List<CanonicalChapter> _chaptersFromAstro(
    List<dynamic> rows,
    String mangaPath,
  ) {
    final chapters = <String, CanonicalChapter>{};

    for (final raw in rows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final number = _number(row['number']);
      if (number == null || number < 0 || number > 20000) continue;
      if (_isLockedChapter(row)) continue;

      final key = ChapterNumberParser.label(number);
      final titleRaw = row['title']?.toString().trim() ?? '';
      final title = titleRaw.isEmpty
          ? 'Chapter $key'
          : 'Chapter $key - ${_plainText(titleRaw)}';
      final published =
          DateTime.tryParse(row['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0);

      final chapterPath = '$mangaPath/chapter/$key';
      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: Uri.encodeComponent(chapterPath),
        reliability: .80,
        publishedAt: published,
        attribution: 'Asura',
      );

      chapters[key] = CanonicalChapter(
        id: 'chapter:number:$key',
        number: number,
        title: title,
        publishedAt: published,
        sourceCopies: [copy],
      );
    }

    final values = chapters.values.toList()
      ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
    return values;
  }

  List<CanonicalChapter> _chaptersFromDom(Document document, String mangaPath) {
    final chapters = <String, CanonicalChapter>{};

    for (final anchor in document.querySelectorAll('a[href*="/chapter/"]')) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final chapterPath = _path(href);
      if (chapterPath == null || !chapterPath.contains('/chapter/')) continue;

      final label = _chapterLabel(anchor);
      final lower = label.toLowerCase();
      if (lower.contains('premium') ||
          lower.contains('locked') ||
          lower.contains('subscribe')) {
        continue;
      }

      final number = ChapterNumberParser.parseVisibleLabel(
        label,
        allowPlainNumber: true,
      );
      if (number == null || number < 0 || number > 20000) continue;

      final key = ChapterNumberParser.label(number);
      final published = _nearbyDate(anchor);
      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: Uri.encodeComponent(chapterPath),
        reliability: .80,
        publishedAt: published,
        attribution: 'Asura',
      );
      chapters[key] = CanonicalChapter(
        id: 'chapter:number:$key',
        number: number,
        title: label.isEmpty ? 'Chapter $key' : label,
        publishedAt: published,
        sourceCopies: [copy],
      );
    }

    final values = chapters.values.toList()
      ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
    return values;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (!path.startsWith('comics/') || !path.contains('/chapter/')) {
      throw const SourceFailure('Invalid Asura chapter.', retryable: false);
    }

    final document = await _documentWithRedirectFallback(path);
    final bodyText = document.body?.text.toLowerCase() ?? '';
    if (bodyText.contains('premium chapter') ||
        bodyText.contains('unlock chapter') ||
        bodyText.contains('subscribe to read')) {
      throw const SourceFailure(
        'This Asura chapter is not publicly readable.',
        retryable: false,
      );
    }

    final astroRoot = _findAstroObject(document, const ['pages']);
    final rawPages = astroRoot?['pages'];
    if (rawPages is List && rawPages.isNotEmpty) {
      final urls = <String>[];
      var tiled = false;
      for (final raw in rawPages.whereType<Map>()) {
        final page = Map<String, dynamic>.from(raw);
        final tiles = page['tiles'];
        if (tiles is List && tiles.isNotEmpty) {
          tiled = true;
          break;
        }
        final value = page['url']?.toString();
        _addTrustedPageUrl(value, urls);
      }

      // Tiled images require source-specific reconstruction. Do not display a
      // scrambled page or attempt to defeat that mechanism; let the canonical
      // chapter fall back to WeebCentral/MangaDex/ComicK instead.
      if (tiled) {
        throw const SourceFailure(
          'This Asura copy uses a protected tiled image format.',
          retryable: false,
        );
      }
      if (urls.isNotEmpty && urls.length <= 600) {
        return ChapterPages(
          chapterId: sourceChapterId,
          sourceId: id,
          urls: urls,
        );
      }
    }

    final urls = <String>[];
    for (final image in document.querySelectorAll(
      'img[alt^="Page"], main img, .reader img, #readerarea img',
    )) {
      final raw =
          image.attributes['data-src'] ??
          image.attributes['data-lazy-src'] ??
          image.attributes['src'];
      _addTrustedPageUrl(raw, urls);
    }

    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('Asura chapter unavailable.');
    }

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final values = await getChapters(sourceMangaId);
    return values.isEmpty ? null : values.last;
  }

  Future<Document> _documentWithRedirectFallback(String path) async {
    try {
      return await _document('/$path');
    } catch (_) {
      // Asura periodically changes the random suffix on public series URLs.
      final stripped = path.replaceFirst(
        RegExp(r'-[a-z0-9]{8}(?=/|$)', caseSensitive: false),
        '',
      );
      if (stripped == path) rethrow;
      return _document('/$stripped');
    }
  }

  Future<Document> _document(String path) async {
    final response = await _client.get<String>(
      path,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://asurascans.com/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }

  Map<String, dynamic>? _findAstroObject(
    Document document,
    List<String> requiredKeys,
  ) {
    for (final element in document.querySelectorAll('[props]')) {
      final props = element.attributes['props'];
      if (props == null || requiredKeys.any((key) => !props.contains(key))) {
        continue;
      }
      try {
        final unwrapped = _unwrapAstro(jsonDecode(props));
        final found = _findMapWithKeys(unwrapped, requiredKeys);
        if (found != null) return found;
      } catch (_) {
        // Keep looking through other islands.
      }
    }
    return null;
  }

  dynamic _unwrapAstro(dynamic value) {
    if (value is List) {
      if (value.isEmpty || value.length == 1) return null;
      if (value.length == 2 && value.first is! List && value.first is! Map) {
        return _unwrapAstro(value[1]);
      }
      return value.map(_unwrapAstro).toList(growable: false);
    }
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _unwrapAstro(entry.value),
      };
    }
    return value;
  }

  Map<String, dynamic>? _findMapWithKeys(
    dynamic value,
    List<String> requiredKeys,
  ) {
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      if (requiredKeys.every(map.containsKey)) return map;
      for (final child in map.values) {
        final found = _findMapWithKeys(child, requiredKeys);
        if (found != null) return found;
      }
    } else if (value is List) {
      for (final child in value) {
        final found = _findMapWithKeys(child, requiredKeys);
        if (found != null) return found;
      }
    }
    return null;
  }

  bool _isLockedChapter(Map<String, dynamic> row) {
    if (row['is_premium'] == true || row['is_locked'] == true) return true;
    final until = DateTime.tryParse(
      row['early_access_until']?.toString() ?? '',
    );
    return until != null && until.isAfter(DateTime.now().toUtc());
  }

  double? _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  List<String> _aliasesFromAstro(Map<String, dynamic>? astro) {
    final raw = astro?['alternativeTitles']?.toString() ?? '';
    if (raw.isEmpty) return const [];
    final pieces = raw.contains('•') ? raw.split('•') : raw.split(',');
    return pieces
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  String _chapterLabel(Element anchor) {
    final span = anchor.querySelector('span')?.text;
    if (span != null && span.trim().isNotEmpty) {
      return span.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  DateTime _nearbyDate(Element anchor) {
    final direct = anchor
        .querySelector('time[datetime]')
        ?.attributes['datetime'];
    final directDate = direct == null ? null : DateTime.tryParse(direct);
    if (directDate != null) return directDate;

    Element? node = anchor.parent;
    for (var depth = 0; depth < 3 && node != null; depth++) {
      final raw = node.querySelector('time[datetime]')?.attributes['datetime'];
      final parsed = raw == null ? null : DateTime.tryParse(raw);
      if (parsed != null) return parsed;
      node = node.parent;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _addTrustedPageUrl(String? raw, List<String> output) {
    if (raw == null || raw.trim().isEmpty) return;
    final url = _absolute(raw);
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) return;
    if (!output.contains(url)) output.add(url);
  }

  String _findCover(Document document) =>
      document
          .querySelector('#desktop-cover-container img')
          ?.attributes['src'] ??
      document.querySelector('article img[alt]')?.attributes['src'] ??
      '';

  String _longestParagraph(Document document) {
    var result = '';
    for (final p in document.querySelectorAll('p')) {
      final text = p.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length > result.length) result = text;
    }
    return result;
  }

  String _plainText(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String? _publicSlug(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final comics = parts.indexOf('comics');
    if (comics >= 0 && comics + 1 < parts.length) return parts[comics + 1];
    return parts.isEmpty ? null : parts.last;
  }

  String? _path(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    return uri.path.replaceFirst(RegExp(r'^/+'), '');
  }

  String _absolute(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('https://')) return trimmed;
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    if (trimmed.startsWith('/')) return 'https://asurascans.com$trimmed';
    return 'https://asurascans.com/$trimmed';
  }
}
