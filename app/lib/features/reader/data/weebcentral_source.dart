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

class WeebCentralSource implements MangaSource {
  WeebCentralSource({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://weebcentral.com');

  final Dio _client;

  @override
  String get id => 'weebcentral';

  @override
  String get displayName => 'WeebCentral';

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
  Future<List<Manga>> search(String query) => _search(query);

  Future<List<Manga>> _search(String query) async {
    final cleaned = query
        .replaceAll(RegExp(r'[!#:(),-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.length < 2) return const [];

    // This mirrors the current maintained WeebCentral source: /search is the
    // shell, while /search/data returns the actual Full Display result cards.
    final document = await _document(
      '/search/data',
      queryParameters: {
        'text': cleaned,
        'limit': 32,
        'offset': 0,
        'display_mode': 'Full Display',
        'sort': 'Best Match',
        'order': 'Descending',
        'official': 'Any',
        'anime': 'Any',
        'adult': 'False',
      },
    );

    final results = <String, Manga>{};

    // Use the card's primary link only. The old implementation consumed every
    // /series/ link inside a card and could overwrite a correct title with
    // unrelated text from another link in the same result.
    var cards = document.querySelectorAll('article > section > a');
    if (cards.isEmpty) {
      cards = document.querySelectorAll('a[href*="/series/"]');
    }

    for (final anchor in cards) {
      final href = anchor.attributes['href'];
      if (href == null) continue;

      final path = _path(href);
      final seriesId = path == null ? null : _seriesId(path);
      if (path == null || seriesId == null) continue;

      var title = '';
      if (anchor.children.isNotEmpty) {
        final last = anchor.children.last;
        if (last.localName == 'div' && !last.attributes.containsKey('class')) {
          title = last.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        }
      }

      if (title.isEmpty) {
        final image = anchor.querySelector('img');
        title = (image?.attributes['alt'] ?? anchor.attributes['title'] ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .replaceFirst(RegExp(r'\s+cover$', caseSensitive: false), '')
            .trim();
      }

      if (title.isEmpty) continue;

      final sourceId = Uri.encodeComponent(path);
      results[path] = Manga(
        id: 'weebcentral:$sourceId',
        title: title,
        coverUrl: _cardImage(anchor),
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
      );
    }

    return results.values.toList(growable: false);
  }

  Future<String?> findConservativeMatch(
    Manga canonical, {
    bool allowAdult = false,
  }) async {
    final queries = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(8);

    // Resolve a strong result as soon as one title/alias works instead of
    // serially executing every alias before making a decision.
    for (final query in queries) {
      try {
        final exactCanonicalNames = <String>{
          canonical.title,
          ...canonical.aliases,
        }.map(SourceMatching.normalize).toSet();

        final candidates = await _search(query);
        if (candidates.isEmpty) continue;

        for (final candidate in candidates) {
          final candidateNames = <String>{
            candidate.title,
            ...candidate.aliases,
          }.map(SourceMatching.normalize);
          if (candidateNames.any(exactCanonicalNames.contains)) {
            return candidate.id.replaceFirst('weebcentral:', '');
          }
        }

        final match = SourceMatching.bestMatchId(
          canonical,
          candidates,
          sourcePrefix: 'weebcentral:',
          minimumScore: .82,
          ambiguityMargin: .025,
        );
        if (match != null) return match;
      } catch (_) {
        // A different title/alias or another source may still work.
      }
    }

    return null;
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final path = Uri.decodeComponent(sourceMangaId);
    if (_seriesId(path) == null) return null;

    final document = await _document('/$path');
    final title = document.querySelector('h1')?.text.trim() ?? '';
    if (title.isEmpty) return null;

    final aliases = <String>{};
    for (final item in document.querySelectorAll('li')) {
      final strong = item.querySelector('strong')?.text.toLowerCase() ?? '';
      if (!strong.contains('associated name')) continue;
      for (final child in item.querySelectorAll('li')) {
        final value = child.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (value.isNotEmpty && value.length < 160) aliases.add(value);
      }
    }

    return Manga(
      id: 'weebcentral:$sourceMangaId',
      title: title,
      aliases: aliases.toList(growable: false),
      coverUrl: _absolute(
        document
                .querySelector('section[x-data] source')
                ?.attributes['srcset'] ??
            document.querySelector('section[x-data] img')?.attributes['src'] ??
            '',
      ),
      synopsis: _longestParagraph(document),
      status: _status(document),
      chapterCount: 0,
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final storedPath = Uri.decodeComponent(sourceMangaId);
    final seriesId = _seriesId(storedPath);
    if (seriesId == null) return const [];

    Document document;
    try {
      // Crucial: this endpoint uses only the series ID. Appending
      // full-chapter-list to /series/<id>/<slug> returns the wrong route.
      document = await _document('/series/$seriesId/full-chapter-list');
      if (_chapterAnchors(document).isEmpty) {
        throw const SourceFailure('WeebCentral full chapter list was empty.');
      }
    } catch (_) {
      final normal = await _document('/$storedPath');
      final bodyText = normal.body?.text.toLowerCase() ?? '';

      // The ordinary series page intentionally contains only newest + oldest
      // rows when Show All Chapters exists. Never cache that abbreviated list
      // as a complete manga.
      if (bodyText.contains('show all chapters')) return const [];
      document = normal;
    }

    return _parseChapters(document);
  }

  List<CanonicalChapter> _parseChapters(Document document) {
    final anchors = _chapterAnchors(document).toList(growable: false);
    if (anchors.isEmpty) return const [];

    final labels = anchors.map(_chapterLabel).toList(growable: false);

    // Some WeebCentral series restart visible chapter numbering each season.
    // In that case, using labels such as "Season 2 Episode 1" would collapse
    // multiple seasons into duplicate Chapter 1 entries. Use the source order
    // as a stable continuous chapter number for those series.
    final useSequentialIndex = labels.any(
      (label) => RegExp(
        r'\b(?:season|s)\s*\d+\b',
        caseSensitive: false,
      ).hasMatch(label),
    );

    final chapters = <String, CanonicalChapter>{};
    final specials = <String, CanonicalChapter>{};

    for (var index = 0; index < anchors.length; index++) {
      final anchor = anchors[index];
      final href = anchor.attributes['href'];
      if (href == null) continue;

      final chapterPath = _path(href);
      if (chapterPath == null || !chapterPath.startsWith('chapters/')) {
        continue;
      }

      final label = labels[index];
      final parsed = _parseChapterNumber(label);
      final number = useSequentialIndex
          ? (anchors.length - index).toDouble()
          : parsed;
      final published = _nearbyDate(anchor);
      final copy = ChapterSourceCopy(
        sourceId: id,
        chapterId: Uri.encodeComponent(chapterPath),
        reliability: .96,
        publishedAt: published,
        attribution: 'WeebCentral',
      );

      if (number == null) {
        // Preserve genuine non-numbered extras/oneshots instead of silently
        // making a manga look as though chapters are missing.
        final specialKey = _specialKey(label, chapterPath);
        specials[specialKey] = CanonicalChapter(
          id: 'chapter:special:$specialKey',
          number: null,
          title: label.isEmpty ? 'Special' : label,
          publishedAt: published,
          sourceCopies: [copy],
        );
        continue;
      }

      if (!number.isFinite || number < 0 || number > 20000) continue;

      final key = ChapterNumberParser.label(number);
      final existing = chapters[key];
      chapters[key] = CanonicalChapter(
        id: 'chapter:number:$key',
        number: number,
        title: label.isEmpty ? 'Chapter $key' : label,
        publishedAt: existing == null
            ? published
            : _earliestMeaningful(existing.publishedAt, published),
        sourceCopies: [...?existing?.sourceCopies, copy],
      );
    }

    final values = <CanonicalChapter>[...chapters.values, ...specials.values]
      ..sort((a, b) {
        final left = a.number;
        final right = b.number;
        if (left != null && right != null) return left.compareTo(right);
        if (left != null) return -1;
        if (right != null) return 1;
        final byDate = a.publishedAt.compareTo(b.publishedAt);
        return byDate != 0 ? byDate : a.title.compareTo(b.title);
      });
    return values;
  }

  List<Element> _chapterAnchors(Document document) {
    var anchors = document.querySelectorAll('div[x-data] > a');
    if (anchors.isEmpty) {
      anchors = document.querySelectorAll('a[href*="/chapters/"]');
    }
    return anchors
        .where(
          (anchor) => (_path(anchor.attributes['href'] ?? '') ?? '').startsWith(
            'chapters/',
          ),
        )
        .toList(growable: false);
  }

  String _chapterLabel(Element anchor) {
    final exact = anchor.querySelector('span.flex > span')?.text;
    if (exact != null && exact.trim().isNotEmpty) {
      return exact.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    for (final selector in const ['span > span', 'span']) {
      final value = anchor
          .querySelector(selector)
          ?.text
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (value != null && value.isNotEmpty && !_looksLikeDate(value)) {
        return value;
      }
    }

    var value = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    value = value.replaceFirst(
      RegExp(r'\s+\d{4}-\d{2}-\d{2}T.*$', caseSensitive: false),
      '',
    );
    return value.trim();
  }

  double? _parseChapterNumber(String label) {
    final standard = ChapterNumberParser.parseVisibleLabel(
      label,
      allowPlainNumber: true,
    );
    if (standard != null) return standard;

    // WeebCentral also has series using labels such as "File 37" or
    // "Guilt 41". This operates only on the isolated chapter-name span, so a
    // single trailing number cannot accidentally be a date/database id.
    final match = RegExp(r'^[^0-9]{1,80}\s+(\d+(?:\.\d+)?)$')
        .firstMatch(label.trim());
    final number = double.tryParse(match?.group(1) ?? '');
    if (number == null || !number.isFinite || number < 0 || number > 20000) {
      return null;
    }
    return number;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final path = Uri.decodeComponent(sourceChapterId);
    if (!path.startsWith('chapters/')) {
      throw const SourceFailure(
        'Invalid WeebCentral chapter.',
        retryable: false,
      );
    }

    Document document;
    try {
      // This is the source's dedicated long-strip image response used by
      // current reader extensions.
      document = await _document(
        '/$path/images',
        queryParameters: {'is_prev': 'False', 'reading_style': 'long_strip'},
      );
    } catch (_) {
      document = await _document('/$path');
    }

    var urls = _pageUrls(document);
    if (urls.isEmpty) {
      final fallback = await _document('/$path');
      urls = _pageUrls(fallback);
    }

    if (urls.isEmpty || urls.length > 600) {
      throw const SourceFailure('WeebCentral chapter unavailable.');
    }

    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  List<String> _pageUrls(Document document) {
    var images = document.querySelectorAll('section[x-data~="scroll"] > img');
    if (images.isEmpty) {
      images = document.querySelectorAll(
        'section img[alt^="Page"], img[alt^="Page"]',
      );
    }

    final urls = <String>[];
    for (final image in images) {
      var raw =
          image.attributes['src'] ??
          image.attributes['data-src'] ??
          image.attributes['data-lazy-src'];

      if ((raw == null || raw.trim().isEmpty) &&
          image.attributes['srcset'] != null) {
        raw = image.attributes['srcset']!
            .split(',')
            .first
            .trim()
            .split(RegExp(r'\s+'))
            .first;
      }

      if (raw == null || raw.trim().isEmpty) continue;
      final url = _absolute(raw);
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
        continue;
      }
      if (!urls.contains(url)) urls.add(url);
    }
    return urls;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final storedPath = Uri.decodeComponent(sourceMangaId);
    if (_seriesId(storedPath) == null) return null;

    // The normal series page always exposes the newest rows, which makes this
    // a cheap update probe even though it is intentionally not a full list.
    final document = await _document('/$storedPath');
    final anchors = _chapterAnchors(document);

    // Series that reset numbering each season need the same sequential index
    // used by the full-list parser; comparing visible `Season 2 Chapter 3`
    // against a cached continuous chapter 120 would otherwise miss updates.
    if (anchors.any(
      (anchor) => RegExp(
        r'\b(?:season|s)\s*\d+\b',
        caseSensitive: false,
      ).hasMatch(_chapterLabel(anchor)),
    )) {
      final values = await getChapters(sourceMangaId);
      CanonicalChapter? newest;
      for (final chapter in values) {
        if (chapter.number == null) continue;
        if (newest == null || chapter.number! > (newest.number ?? -1)) {
          newest = chapter;
        }
      }
      return newest;
    }

    CanonicalChapter? latest;

    for (final anchor in anchors) {
      final href = anchor.attributes['href'];
      final path = href == null ? null : _path(href);
      if (path == null || !path.startsWith('chapters/')) continue;

      final label = _chapterLabel(anchor);
      final number = _parseChapterNumber(label);
      if (number == null) continue;

      final published = _nearbyDate(anchor);
      final chapter = CanonicalChapter(
        id: 'chapter:number:${ChapterNumberParser.label(number)}',
        number: number,
        title: label,
        publishedAt: published,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: id,
            chapterId: Uri.encodeComponent(path),
            reliability: .96,
            publishedAt: published,
            attribution: 'WeebCentral',
          ),
        ],
      );

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
        responseType: ResponseType.plain,
        headers: const {'Referer': 'https://weebcentral.com/'},
      ),
    );
    return html_parser.parse(response.data ?? '');
  }

  String _cardImage(Element anchor) {
    final source = anchor.querySelector('source')?.attributes['srcset'];
    if (source != null && source.trim().isNotEmpty) {
      final first = source.split(',').first.trim().split(RegExp(r'\s+')).first;
      return _absolute(first.replaceAll('small', 'normal'));
    }
    return _absolute(anchor.querySelector('img')?.attributes['src'] ?? '');
  }

  DateTime _nearbyDate(Element anchor) {
    final direct = anchor.querySelector('time[datetime]');
    final directRaw = direct?.attributes['datetime'];
    final directDate = directRaw == null ? null : DateTime.tryParse(directRaw);
    if (directDate != null) return directDate;

    Element? node = anchor.parent;
    for (var depth = 0; depth < 3 && node != null; depth++) {
      final time = node.querySelector('time[datetime]');
      final raw = time?.attributes['datetime'];
      final parsed = raw == null ? null : DateTime.tryParse(raw);
      if (parsed != null) return parsed;
      node = node.parent;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _earliestMeaningful(DateTime left, DateTime right) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (left == epoch) return right;
    if (right == epoch) return left;
    return left.isBefore(right) ? left : right;
  }

  MangaStatus _status(Document document) {
    for (final item in document.querySelectorAll('li')) {
      final label = item.querySelector('strong')?.text.toLowerCase() ?? '';
      if (!label.contains('status')) continue;
      final status = (item.querySelector('a')?.text ?? item.text)
          .toLowerCase()
          .replaceAll('status', '')
          .replaceAll(':', '')
          .trim();
      if (status.contains('ongoing')) return MangaStatus.ongoing;
      if (status.contains('complete')) return MangaStatus.completed;
      if (status.contains('hiatus')) return MangaStatus.hiatus;
      if (status.contains('canceled') || status.contains('cancelled')) {
        return MangaStatus.cancelled;
      }
    }
    return MangaStatus.unknown;
  }

  String _longestParagraph(Document document) {
    var result = '';
    for (final paragraph in document.querySelectorAll('p')) {
      final text = paragraph.text.trim();
      if (text.length > result.length) result = text;
    }
    return result;
  }

  String _specialKey(String label, String chapterPath) {
    final normalized = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (normalized.isNotEmpty) return normalized;
    return chapterPath.split('/').last;
  }

  bool _looksLikeDate(String value) =>
      RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(value.trim());

  String? _seriesId(String path) {
    final clean = path.replaceFirst(RegExp(r'^/+'), '');
    final parts = clean.split('/');
    if (parts.length < 2 || parts[0] != 'series') return null;
    final value = parts[1].trim();
    return value.isEmpty ? null : value;
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
    if (trimmed.startsWith('/')) return 'https://weebcentral.com$trimmed';
    return 'https://weebcentral.com/$trimmed';
  }
}
