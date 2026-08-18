import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'manga_source.dart';

class ComicKSource implements MangaSource {
  ComicKSource({Dio? apiClient, Dio? webClient})
    : _apiClient =
          apiClient ?? createHttpClient(baseUrl: 'https://api.comick.io'),
      _webClient = webClient ?? createHttpClient(baseUrl: 'https://comick.io');

  final Dio _apiClient;
  final Dio _webClient;

  @override
  String get id => 'comick';

  @override
  String get displayName => 'ComicK';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: false,
    chapters: true,
    pages: true,
    updates: false,
  );

  @override
  Set<String> get allowedImageHosts => const {'meo.comick.pictures'};

  @override
  Future<List<Manga>> search(String query) async {
    final rows = await _searchRows(query);

    return rows.map(_toManga).whereType<Manga>().toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final expected = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(_normalize).where((value) => value.isNotEmpty).toSet();

    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    for (final query in queries) {
      try {
        final rows = await _searchRows(query);

        for (final row in rows) {
          final titles = <String>{
            if (row['title'] is String) row['title'] as String,
            ...((row['md_titles'] as List? ?? const [])
                .whereType<Map>()
                .map((item) => item['title'])
                .whereType<String>()),
          }.map(_normalize).where((value) => value.isNotEmpty);

          if (!titles.any(expected.contains)) {
            continue;
          }

          final hid = row['hid']?.toString();
          final slug = row['slug']?.toString();

          if (hid == null || hid.isEmpty || slug == null || slug.isEmpty) {
            continue;
          }

          return '${Uri.encodeComponent(hid)}|'
              '${Uri.encodeComponent(slug)}';
        }
      } catch (_) {
        // Continue with another alias.
      }
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> _searchRows(String query) async {
    final response = await _apiClient.get<dynamic>(
      '/v1.0/search',
      queryParameters: {'q': query, 'limit': 20},
      options: Options(headers: const {'Referer': 'https://comick.io/'}),
    );

    final raw = response.data;

    if (raw is! List) {
      return const [];
    }

    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  Manga? _toManga(Map<String, dynamic> row) {
    final hid = row['hid']?.toString();
    final slug = row['slug']?.toString();
    final title = row['title']?.toString();

    if (hid == null || slug == null || title == null || title.isEmpty) {
      return null;
    }

    final aliases = (row['md_titles'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => item['title'])
        .whereType<String>()
        .toList(growable: false);

    final rating = row['content_rating']?.toString();

    String coverUrl = '';

    for (final cover
        in (row['md_covers'] as List? ?? const []).whereType<Map>()) {
      final key = cover['b2key']?.toString();

      if (key != null && key.isNotEmpty) {
        coverUrl = 'https://meo.comick.pictures/$key';
        break;
      }
    }

    return Manga(
      id:
          'comick:${Uri.encodeComponent(hid)}|'
          '${Uri.encodeComponent(slug)}',
      title: title,
      aliases: aliases,
      coverUrl: coverUrl,
      synopsis: row['desc']?.toString() ?? '',
      status: MangaStatus.unknown,
      chapterCount: _integerValue(row['last_chapter']),
      isAdult: rating == 'erotica' || rating == 'pornographic',
    );
  }

  int _integerValue(dynamic value) {
    if (value is num) {
      return value.toInt();
    }

    return double.tryParse(value?.toString() ?? '')?.toInt() ?? 0;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    // AniList remains Tsuki's metadata provider.
    return null;
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final parts = sourceMangaId.split('|');

    if (parts.length != 2) {
      return const [];
    }

    final hid = Uri.decodeComponent(parts[0]);

    final slug = Uri.decodeComponent(parts[1]);

    final chapters = <String, CanonicalChapter>{};

    const pageSize = 100;

    for (var page = 1; page <= 100; page++) {
      final response = await _apiClient.get<dynamic>(
        '/comic/$hid/chapters',
        queryParameters: {'lang': 'en', 'limit': pageSize, 'page': page},
        options: Options(headers: const {'Referer': 'https://comick.io/'}),
      );

      final root = response.data;

      dynamic rawRows;

      if (root is Map) {
        rawRows = root['chapters'] ?? root['data'];
      } else if (root is List) {
        rawRows = root;
      }

      if (rawRows is! List || rawRows.isEmpty) {
        break;
      }

      for (final raw in rawRows.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);

        final language = row['lang']?.toString();

        if (language != null && language.isNotEmpty && language != 'en') {
          continue;
        }

        final chapterText =
            (row['chap'] ?? row['chapter'] ?? row['chapter_number'])
                ?.toString()
                .trim() ??
            '';

        final number = _parseNumber(chapterText);

        if (number == null) {
          continue;
        }

        final chapterHid = (row['hid'] ?? row['chapter_hid'] ?? row['id'])
            ?.toString();

        if (chapterHid == null || chapterHid.isEmpty) {
          continue;
        }

        final title = row['title']?.toString().trim() ?? '';

        final published =
            DateTime.tryParse(
              row['publish_at']?.toString() ??
                  row['created_at']?.toString() ??
                  '',
            ) ??
            DateTime.fromMillisecondsSinceEpoch(0);

        final key = _numberLabel(number);

        final previous = chapters[key];

        final copy = ChapterSourceCopy(
          sourceId: id,
          chapterId: [
            Uri.encodeComponent(slug),
            Uri.encodeComponent(chapterHid),
            Uri.encodeComponent(chapterText),
            'en',
          ].join('|'),
          reliability: .78,
          publishedAt: published,
          attribution: 'ComicK',
        );

        chapters[key] = CanonicalChapter(
          id: 'chapter:number:$key',
          number: number,
          title: title.isEmpty ? 'Chapter $key' : title,
          publishedAt:
              previous == null || published.isBefore(previous.publishedAt)
              ? published
              : previous.publishedAt,
          sourceCopies: [...?previous?.sourceCopies, copy],
        );
      }

      if (rawRows.length < pageSize) {
        break;
      }
    }

    final result = chapters.values.toList()
      ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

    return result;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final parts = sourceChapterId.split('|');

    if (parts.length != 4) {
      throw const SourceFailure(
        'ComicK chapter reference is invalid.',
        retryable: false,
      );
    }

    final slug = Uri.decodeComponent(parts[0]);

    final hid = Uri.decodeComponent(parts[1]);

    final number = Uri.decodeComponent(parts[2]);

    final language = Uri.decodeComponent(parts[3]);

    final response = await _webClient.get<String>(
      '/comic/$slug/'
      '$hid-chapter-$number-$language',
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://comick.io/'},
      ),
    );

    final document = html_parser.parse(response.data ?? '');

    final urls = <String>[];

    final nextData = document.querySelector('script#__NEXT_DATA__')?.text;

    if (nextData != null && nextData.isNotEmpty) {
      try {
        _findImages(jsonDecode(nextData), urls);
      } catch (_) {
        // Fall back to regular images.
      }
    }

    if (urls.isEmpty) {
      for (final image in document.querySelectorAll('img')) {
        final raw = image.attributes['data-src'] ?? image.attributes['src'];

        if (raw == null) {
          continue;
        }

        final url = _imageUrl(raw);

        if (url != null && !urls.contains(url)) {
          urls.add(url);
        }
      }
    }

    if (urls.isEmpty || urls.length > 500) {
      throw const SourceFailure('ComicK chapter pages are unavailable.');
    }

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  void _findImages(dynamic value, List<String> output) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key == 'b2key' && entry.value is String) {
          final url = _imageUrl(entry.value as String);

          if (url != null && !output.contains(url)) {
            output.add(url);
          }
        }

        _findImages(entry.value, output);
      }
    } else if (value is List) {
      for (final child in value) {
        _findImages(child, output);
      }
    }
  }

  String? _imageUrl(String value) {
    final trimmed = value.trim();

    if (trimmed.isEmpty || trimmed.contains('..')) {
      return null;
    }

    final String url;

    if (trimmed.startsWith('https://')) {
      url = trimmed;
    } else if (trimmed.startsWith('//')) {
      url = 'https:$trimmed';
    } else {
      url =
          'https://meo.comick.pictures/'
          '${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
    }

    final uri = Uri.tryParse(url);

    if (uri == null || uri.scheme != 'https') {
      return null;
    }

    return url;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);

    return chapters.isEmpty ? null : chapters.last;
  }

  double? _parseNumber(String value) {
    final direct = double.tryParse(value);

    if (direct != null) {
      return direct;
    }

    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(value);

    return double.tryParse(match?.group(1) ?? '');
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
