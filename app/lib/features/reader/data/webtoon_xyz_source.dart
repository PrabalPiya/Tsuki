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

/// Optional WebtoonXYZ fallback using the site's ordinary public Madara HTML.
///
/// Important: this adapter does not attempt to bypass anti-bot/Cloudflare
/// challenges. If the site returns a challenge page, Tsuki treats the source
/// as unavailable and continues to another provider.
class WebtoonXyzSource implements MangaSource {
  WebtoonXyzSource({Dio? client})
      : _client = client ?? createHttpClient(baseUrl: 'https://www.webtoon.xyz');

  final Dio _client;

  @override
  String get id => 'webtoonxyz';

  @override
  String get displayName => 'WebtoonXYZ';

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

  static const _baseHeaders = <String, String>{
    'Referer': 'https://www.webtoon.xyz/',
    'Accept': 'text/html,application/xhtml+xml',
  };

  @override
  Future<List<Manga>> search(String query) async {
    final cleaned = query.trim();
    if (cleaned.length < 2) return const [];

    final document = await _document(
      '/',
      queryParameters: {
        's': cleaned,
        'post_type': 'wp-manga',
      },
    );

    final results = <String, Manga>{};
    final cards = <Element>[
      ...document.querySelectorAll('div.c-tabs-item__content'),
      ...document.querySelectorAll('.manga__item'),
    ];

    for (final card in cards) {
      final link = card.querySelector('div.post-title a') ??
          card.querySelector('a[href*="/read/"]');
      if (link == null) continue;
      final href = link.attributes['href'] ?? '';
      final path = _path(href);
      if (path == null || !path.startsWith('read/')) continue;

      final title = link.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (title.isEmpty) continue;

      final image = card.querySelector('img');
      final cover = _absolute(
        image?.attributes['data-src'] ??
            image?.attributes['data-lazy-src'] ??
            image?.attributes['src'] ??
            '',
      );

      final encoded = Uri.encodeComponent(path);
      results[path] = Manga(
        id: 'webtoonxyz:$encoded',
        title: title,
        coverUrl: cover,
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
      );
    }

    return results.values.toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final expected = <String>{canonical.title, ...canonical.aliases}
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
          final names = <String>{candidate.title, ...candidate.aliases}
              .map(SourceMatching.normalize);
          if (names.any(expected.contains)) {
            return candidate.id.replaceFirst('webtoonxyz:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'webtoonxyz:',
          minimumScore: .80,
          ambiguityMargin: .025,
        );
        if (match != null) return match;
      } catch (_) {
        // Challenge pages / temporary failures are expected to fall through.
      }
    }
    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (!path.startsWith('read/')) return null;
    final document = await _document('/$path');
    final title = document.querySelector('.post-title h1')?.text.trim() ??
        document.querySelector('h1')?.text.trim() ??
        '';
    if (title.isEmpty) return null;

    return Manga(
      id: 'webtoonxyz:$sourceMangaId',
      title: title,
      coverUrl: _absolute(
        document.querySelector('.summary_image img')?.attributes['data-src'] ??
            document.querySelector('.summary_image img')?.attributes['src'] ??
            '',
      ),
      synopsis: document.querySelector('.summary__content')?.text.trim() ?? '',
      status: MangaStatus.unknown,
      chapterCount: 0,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (!path.startsWith('read/')) return const [];

    var document = await _document('/$path');
    var rows = document.querySelectorAll('li.wp-manga-chapter');

    // Current Madara sources commonly lazy-load the full list through
    // /ajax/chapters. Use the public endpoint when the initial HTML is empty.
    if (rows.isEmpty &&
        document.querySelector('div[id^="manga-chapters-holder"]') != null) {
      try {
        final response = await _client.post<String>(
          '/$path/ajax/chapters',
          options: Options(
            headers: const {
              'Referer': 'https://www.webtoon.xyz/',
              'X-Requested-With': 'XMLHttpRequest',
              'Accept': 'text/html,*/*',
            },
            responseType: ResponseType.plain,
          ),
        );
        _ensureOrdinaryPage(response.data ?? '');
        document = html_parser.parse(response.data ?? '');
        rows = document.querySelectorAll('li.wp-manga-chapter');
      } catch (_) {
        // Keep the original page result; caller will fall back to another source.
      }
    }

    final values = <CanonicalChapter>[];
    for (final row in rows.reversed) {
      final anchor = row.querySelector('a');
      final href = anchor?.attributes['href'] ?? '';
      final chapterPath = _path(href);
      if (chapterPath == null) continue;

      final label = (anchor?.text ?? row.text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final number = ChapterNumberParser.parseVisibleLabel(
        label,
        allowPlainNumber: true,
      );
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }

      final dateText = row
          .querySelector('span.chapter-release-date')
          ?.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final published = _parseDate(dateText);
      final idPart = number == null
          ? 'special:${_safeKey(label, chapterPath)}'
          : 'number:${ChapterNumberParser.label(number)}';

      values.add(
        CanonicalChapter(
          id: 'chapter:$idPart',
          number: number,
          title: label.isEmpty
              ? (number == null
                  ? 'Special'
                  : 'Chapter ${ChapterNumberParser.label(number)}')
              : label,
          publishedAt: published,
          sourceCopies: [
            ChapterSourceCopy(
              sourceId: id,
              chapterId: Uri.encodeComponent(chapterPath),
              reliability: .58,
              publishedAt: published,
              attribution: 'WebtoonXYZ',
            ),
          ],
        ),
      );
    }

    return values;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (path.isEmpty) {
      throw const SourceFailure('Invalid WebtoonXYZ chapter.', retryable: false);
    }

    final document = await _document('/$path');
    final urls = <String>[];
    final seen = <String>{};

    for (final selector in const [
      'div.page-break img',
      'li.blocks-gallery-item img',
      '.reading-content img',
    ]) {
      for (final image in document.querySelectorAll(selector)) {
        final raw = image.attributes['data-src'] ??
            image.attributes['data-lazy-src'] ??
            image.attributes['data-original'] ??
            image.attributes['src'] ??
            '';
        final value = _absolute(raw);
        final uri = Uri.tryParse(value);
        if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) continue;
        if (seen.add(value)) urls.add(value);
      }
    }

    if (urls.isEmpty || urls.length > 700) {
      throw const SourceFailure('WebtoonXYZ chapter unavailable.');
    }

    return ChapterPages(
      chapterId: sourceChapterId,
      sourceId: id,
      urls: urls,
    );
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    CanonicalChapter? latest;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number == null) continue;
      if (latest == null || number > (latest.number ?? -1)) latest = chapter;
    }
    return latest;
  }

  Future<Document> _document(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _client.get<String>(
      path,
      queryParameters: queryParameters,
      options: Options(
        headers: _baseHeaders,
        responseType: ResponseType.plain,
      ),
    );
    final body = response.data ?? '';
    _ensureOrdinaryPage(body);
    return html_parser.parse(body);
  }

  void _ensureOrdinaryPage(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('just a moment') ||
        lower.contains('cf-chl-') ||
        lower.contains('cloudflare ray id')) {
      throw const SourceFailure('WebtoonXYZ is protected right now.');
    }
  }

  String? _path(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    final path = uri.path.replaceFirst(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    return path.isEmpty ? null : path;
  }

  String _absolute(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    if (uri.hasScheme) return uri.toString();
    return Uri.parse('https://www.webtoon.xyz/').resolveUri(uri).toString();
  }

  DateTime _parseDate(String? value) {
    if (value == null || value.trim().isEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    final raw = value.trim();
    final direct = DateTime.tryParse(raw);
    if (direct != null) return direct;

    const months = <String, int>{
      'january': 1,
      'february': 2,
      'march': 3,
      'april': 4,
      'may': 5,
      'june': 6,
      'july': 7,
      'august': 8,
      'september': 9,
      'october': 10,
      'november': 11,
      'december': 12,
    };
    final match = RegExp(r'^(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})$').firstMatch(raw);
    if (match == null) return DateTime.fromMillisecondsSinceEpoch(0);
    final month = months[match.group(2)!.toLowerCase()];
    final day = int.tryParse(match.group(1)!);
    final year = int.tryParse(match.group(3)!);
    if (month == null || day == null || year == null) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime(year, month, day);
  }

  String _safeKey(String label, String path) =>
      '${SourceMatching.normalize(label)}-${path.hashCode.abs()}';
}
