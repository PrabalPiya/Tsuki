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

/// ComicK provider using the current website/API shape.
///
/// The previous Tsuki implementation used the older api.comick.io endpoints.
/// The maintained reader source now uses comick.live/comick.art with
/// /api/search and /api/comics/<slug>/chapter-list.
class ComicKSource implements MangaSource {
  ComicKSource({Dio? client, Dio? mirrorClient})
      : _client = client ?? createHttpClient(baseUrl: 'https://comick.live'),
        _mirrorClient =
            mirrorClient ?? createHttpClient(baseUrl: 'https://comick.art');

  final Dio _client;
  final Dio _mirrorClient;

  @override
  String get id => 'comick';

  @override
  String get displayName => 'ComicK';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
        search: true,
        chapters: true,
        pages: true,
        updates: true,
      );

  @override
  Set<String> get allowedImageHosts => const {};

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 3) return const [];

    final response = await _get<dynamic>(
      '/api/search',
      queryParameters: {
        'q': cleaned,
        'type': 'comic',
        'showAll': 'false',
        'exclude_mylist': 'false',
        'order_by': 'created_at',
        'order_direction': 'desc',
      },
      options: Options(
        headers: const {'Referer': 'https://comick.live/'},
      ),
    );

    final root = response.data;
    final rawRows = root is Map ? root['data'] : null;
    if (rawRows is! List) return const [];

    final values = <Manga>[];
    for (final raw in rawRows.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final slug = row['slug']?.toString().trim() ?? '';
      final title = row['title']?.toString().trim() ?? '';
      if (slug.isEmpty || title.isEmpty) continue;

      values.add(
        Manga(
          id: 'comick:${Uri.encodeComponent(slug)}',
          title: title,
          coverUrl: row['default_thumbnail']?.toString() ?? '',
          synopsis: '',
          status: MangaStatus.unknown,
          chapterCount: 0,
        ),
      );
    }

    return values;
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final canonicalNames = <String>{canonical.title, ...canonical.aliases}
        .map(SourceMatching.normalize)
        .where((value) => value.isNotEmpty)
        .toSet();

    final queries = <String>{canonical.title, ...canonical.aliases}
        .map((value) => value.trim())
        .where((value) => value.length >= 3)
        .take(8);

    for (final query in queries) {
      try {
        final candidates = await search(query);
        if (candidates.isEmpty) continue;

        for (final candidate in candidates) {
          final candidateNames = <String>{candidate.title, ...candidate.aliases}
              .map(SourceMatching.normalize);
          if (candidateNames.any(canonicalNames.contains)) {
            return candidate.id.replaceFirst('comick:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'comick:',
          minimumScore: .84,
          ambiguityMargin: .03,
        );
        if (match != null) return match;
      } catch (_) {
        // Another alias/source can still resolve the manga.
      }
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    // Details are supplied by AniList in Tsuki. Avoid an unnecessary network
    // request here; chapter/page operations use the ComicK slug directly.
    return null;
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final slug = Uri.decodeComponent(sourceMangaId).trim();
    if (slug.isEmpty || slug.contains('/')) return const [];

    final chapters = <String, CanonicalChapter>{};
    var page = 1;
    var lastPage = 1;

    do {
      final payload = await _chapterPage(slug, page);
      final rows = payload.rows;
      lastPage = payload.lastPage < page ? page : payload.lastPage;

      for (final row in rows) {
        final parsed = _chapterFromRow(slug, row);
        if (parsed == null) continue;
        final key = parsed.number == null
            ? 'special:${_specialKey(parsed.title, parsed.sourceCopies.first.chapterId)}'
            : 'number:${ChapterNumberParser.label(parsed.number!)}';

        final existing = chapters[key];
        if (existing == null) {
          chapters[key] = parsed;
          continue;
        }

        chapters[key] = CanonicalChapter(
          id: existing.id,
          number: existing.number ?? parsed.number,
          title: _betterTitle(existing.title, parsed.title),
          publishedAt: _earliestMeaningful(
            existing.publishedAt,
            parsed.publishedAt,
          ),
          sourceCopies: [
            ...existing.sourceCopies,
            ...parsed.sourceCopies,
          ],
        );
      }

      page++;
      if (page > 200) break; // corruption/runaway guard only
    } while (page <= lastPage);

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

  Future<({List<Map<String, dynamic>> rows, int lastPage})> _chapterPage(
    String slug,
    int page,
  ) async {
    final response = await _get<dynamic>(
      '/api/comics/$slug/chapter-list',
      queryParameters: {
        'lang': 'en',
        'page': page,
      },
      options: Options(
        headers: const {'Referer': 'https://comick.live/'},
      ),
    );

    final root = response.data;
    if (root is! Map) {
      return (
        rows: const <Map<String, dynamic>>[],
        lastPage: page,
      );
    }

    final rawRows = root['data'];
    final rows = rawRows is List
        ? rawRows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    final pagination = root['pagination'];
    var lastPage = page;
    if (pagination is Map) {
      lastPage = (pagination['last_page'] as num?)?.toInt() ?? page;
    }

    return (rows: rows, lastPage: lastPage);
  }

  CanonicalChapter? _chapterFromRow(
    String slug,
    Map<String, dynamic> row,
  ) {
    final language = row['lang']?.toString().trim();
    if (language != null && language.isNotEmpty && language != 'en') {
      return null;
    }

    final chapterRaw = row['chap']?.toString().trim() ?? '';
    if (chapterRaw.isEmpty) return null;

    // `chap` is a structured ComicK chapter field. Plain numbers are safe.
    final number = double.tryParse(chapterRaw) ??
        ChapterNumberParser.parseVisibleLabel(
          chapterRaw,
          allowPlainNumber: true,
        );

    if (number != null &&
        (!number.isFinite || number < 0 || number > 20000)) {
      return null;
    }

    final hid = row['hid']?.toString().trim() ?? '';
    if (hid.isEmpty) return null;

    final titleRaw = row['title']?.toString().trim() ?? '';
    final key = number == null
        ? _specialKey(titleRaw.isEmpty ? chapterRaw : titleRaw, hid)
        : ChapterNumberParser.label(number);
    final title = titleRaw.isEmpty
        ? (number == null ? chapterRaw : 'Chapter $key')
        : titleRaw;
    final published = DateTime.tryParse(row['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);

    final groups = (row['group_name'] as List? ?? const [])
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);

    final chapterPath =
        'comic/$slug/$hid-chapter-$chapterRaw-en';

    return CanonicalChapter(
      id: number == null ? 'chapter:special:$key' : 'chapter:number:$key',
      number: number,
      title: title,
      publishedAt: published,
      sourceCopies: [
        ChapterSourceCopy(
          sourceId: id,
          chapterId: Uri.encodeComponent(chapterPath),
          reliability: .94,
          publishedAt: published,
          attribution: groups.isEmpty
              ? 'ComicK'
              : 'ComicK - ${groups.join(', ')}',
        ),
      ],
    );
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (!path.startsWith('comic/') || !path.contains('-chapter-')) {
      throw const SourceFailure(
        'ComicK chapter reference is invalid.',
        retryable: false,
      );
    }

    final response = await _get<String>(
      '/$path',
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://comick.live/'},
      ),
    );

    final document = html_parser.parse(response.data ?? '');
    final root = _embeddedJson(document, '#sv-data');
    final chapter = root?['chapter'];
    final rawImages = chapter is Map ? chapter['images'] : null;

    final urls = <String>[];
    if (rawImages is List) {
      for (final raw in rawImages.whereType<Map>()) {
        final url = raw['url']?.toString().trim() ?? '';
        if (_validHttps(url) && !urls.contains(url)) urls.add(url);
      }
    }

    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('ComicK chapter pages are unavailable.');
    }

    return ChapterPages(
      chapterId: sourceChapterId,
      sourceId: id,
      urls: urls,
    );
  }

  Future<Response<T>> _get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
  }) async {
    try {
      return await _client.get<T>(
        path,
        queryParameters: queryParameters,
        options: options,
      );
    } on DioException {
      return _mirrorClient.get<T>(
        path,
        queryParameters: queryParameters,
        options: options,
      );
    }
  }

  Map<String, dynamic>? _embeddedJson(Document document, String selector) {
    final element = document.querySelector(selector);
    if (element == null) return null;

    final candidates = <String>[
      element.text,
      element.innerHtml,
    ];

    for (final raw in candidates) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Try the next representation.
      }
    }
    return null;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final slug = Uri.decodeComponent(sourceMangaId).trim();
    if (slug.isEmpty || slug.contains('/')) return null;

    final first = await _chapterPage(slug, 1);
    final rows = <Map<String, dynamic>>[...first.rows];

    // If the endpoint happens to be ascending, the last page contains the
    // newest chapters. If it is descending, page 1 already does. Checking both
    // ends keeps the update probe correct with at most two requests.
    if (first.lastPage > 1) {
      final last = await _chapterPage(slug, first.lastPage);
      rows.addAll(last.rows);
    }

    CanonicalChapter? latest;
    for (final row in rows) {
      final chapter = _chapterFromRow(slug, row);
      if (chapter == null || chapter.number == null) continue;
      if (latest == null || chapter.number! > (latest.number ?? -1)) {
        latest = chapter;
      }
    }
    return latest;
  }

  bool _validHttps(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  DateTime _earliestMeaningful(DateTime left, DateTime right) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (left == epoch) return right;
    if (right == epoch) return left;
    return left.isBefore(right) ? left : right;
  }

  String _betterTitle(String left, String right) {
    final generic = RegExp(
      r'^(?:chapter|ch\.?)\s*#?\s*\d+(?:\.\d+)?$',
      caseSensitive: false,
    );
    if (generic.hasMatch(left) && !generic.hasMatch(right)) return right;
    if (!generic.hasMatch(left) && generic.hasMatch(right)) return left;
    return right.length > left.length ? right : left;
  }

  String _specialKey(String title, String chapterId) {
    final value = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return value.isNotEmpty ? value : chapterId;
  }
}
