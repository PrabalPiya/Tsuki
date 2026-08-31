import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import 'metadata_provider.dart';

/// Metadata from WEBTOON's public English catalogue pages.
///
/// WEBTOON does not publish a supported metadata API, so page failures are
/// surfaced to the repository and isolated from the other metadata sources.
class WebtoonMetadataProvider implements MetadataProvider {
  WebtoonMetadataProvider({Dio? client})
    : _client = client ?? createHttpClient(baseUrl: 'https://www.webtoons.com');

  final Dio _client;
  final Map<String, Manga> _cache = <String, Manga>{};
  final Map<String, String> _detailPaths = <String, String>{};

  @override
  String get id => 'webtoon';

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    final value = query.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (value.length < 2) return const <Manga>[];

    final response = await _client.get<String>(
      '/en/search',
      cancelToken: cancelToken,
      queryParameters: {'keyword': value},
      options: Options(responseType: ResponseType.plain),
    );
    final document = html_parser.parse(response.data ?? '');
    final results = <String, Manga>{};
    for (final anchor in document.querySelectorAll(
      '.webtoon_list a[data-title-no], .webtoon_list a[href*="title_no="]',
    )) {
      final titleNo = _titleNo(anchor);
      final path = _detailPath(anchor.attributes['href']);
      final title = _text(anchor.querySelector('.title'));
      if (titleNo == null || path == null || title.isEmpty) continue;

      final image = anchor.querySelector('img');
      final manga = Manga(
        id: 'tsuki:webtoon:$titleNo',
        metadataProviderIds: {id: titleNo},
        title: title,
        authors: _splitAuthors(_text(anchor.querySelector('.author'))),
        coverUrl: _absoluteUrl(
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '',
        ),
        synopsis: '',
        status: _status(title),
        chapterCount: 0,
        format: MangaFormat.manga,
        countryCode: 'KR',
        popularity: _compactNumber(_text(anchor.querySelector('.view_count'))),
      );
      if (!manga.isFriendlyContent) continue;
      results[titleNo] = manga;
      _cache[titleNo] = manga;
      _detailPaths[titleNo] = path;
    }
    return results.values.take(20).toList(growable: false);
  }

  @override
  Future<Manga?> getById(String rawId) async {
    final titleNo = _cleanId(rawId);
    if (titleNo == null) return null;
    final path = _detailPaths[titleNo];
    if (path == null) return _cache[titleNo];

    final response = await _client.get<String>(
      path,
      queryParameters: {'title_no': titleNo},
      options: Options(responseType: ResponseType.plain),
    );
    final document = html_parser.parse(response.data ?? '');
    final title = _text(document.querySelector('.detail_header .subj'));
    if (title.isEmpty) return null;

    final synopsis = _text(document.querySelector('.aside.detail .summary'));
    final genre = _text(document.querySelector('.detail_header .genre'));
    final authorText = _text(
      document.querySelector('.detail_header .author_area'),
    ).replaceAll(RegExp(r'author\s+info', caseSensitive: false), '');
    final cover = document.querySelector('.detail_header .thmb img');
    final episodeNumbers = document
        .querySelectorAll('[data-episode-no]')
        .map(
          (element) =>
              int.tryParse(element.attributes['data-episode-no'] ?? ''),
        )
        .whereType<int>();
    final chapterCount = episodeNumbers.isEmpty
        ? 0
        : episodeNumbers.reduce((left, right) => left > right ? left : right);

    final manga = Manga(
      id: 'tsuki:webtoon:$titleNo',
      metadataProviderIds: {id: titleNo},
      title: title,
      authors: _splitAuthors(authorText),
      coverUrl: _absoluteUrl(cover?.attributes['src'] ?? ''),
      synopsis: synopsis,
      status: _status(document.body?.text ?? title),
      chapterCount: chapterCount,
      format: MangaFormat.manga,
      countryCode: 'KR',
      genres: genre.isEmpty ? const <String>[] : <String>[genre],
    );
    if (!manga.isFriendlyContent) return null;
    _cache[titleNo] = manga;
    return manga;
  }

  String? _titleNo(Element anchor) {
    final attribute = anchor.attributes['data-title-no']?.trim();
    if (attribute != null && RegExp(r'^\d+$').hasMatch(attribute)) {
      return attribute;
    }
    final uri = Uri.tryParse(anchor.attributes['href'] ?? '');
    final value = uri?.queryParameters['title_no'];
    return value != null && RegExp(r'^\d+$').hasMatch(value) ? value : null;
  }

  String? _detailPath(String? raw) {
    final uri = Uri.tryParse(raw ?? '');
    if (uri == null ||
        !uri.path.startsWith('/en/') ||
        (uri.host.isNotEmpty && uri.host != 'www.webtoons.com')) {
      return null;
    }
    final titleNo = uri.queryParameters['title_no'];
    if (titleNo == null || !RegExp(r'^\d+$').hasMatch(titleNo)) return null;
    return uri.path;
  }

  String? _cleanId(String raw) {
    final value = raw
        .trim()
        .replaceFirst('tsuki:webtoon:', '')
        .replaceFirst('webtoon:', '');
    return RegExp(r'^\d+$').hasMatch(value) ? value : null;
  }

  String _text(Element? element) =>
      (element?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

  List<String> _splitAuthors(String value) => value
      .split(RegExp(r'\s*(?:/|,)\s*'))
      .map((author) => author.trim())
      .where((author) => author.isNotEmpty && author != '...')
      .toSet()
      .toList(growable: false);

  MangaStatus _status(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('completed')) return MangaStatus.completed;
    if (normalized.contains('hiatus') || normalized.contains('will return')) {
      return MangaStatus.hiatus;
    }
    if (normalized.contains('every ') || normalized.contains('up')) {
      return MangaStatus.ongoing;
    }
    return MangaStatus.unknown;
  }

  int? _compactNumber(String value) {
    final match = RegExp(
      r'([0-9]+(?:\.[0-9]+)?)\s*([kmb])?',
      caseSensitive: false,
    ).firstMatch(value.replaceAll(',', ''));
    final amount = double.tryParse(match?.group(1) ?? '');
    if (amount == null) return null;
    final multiplier = switch (match?.group(2)?.toLowerCase()) {
      'k' => 1000,
      'm' => 1000000,
      'b' => 1000000000,
      _ => 1,
    };
    return (amount * multiplier).round();
  }

  String _absoluteUrl(String raw) {
    final value = raw.trim();
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/')) return 'https://www.webtoons.com$value';
    return value;
  }
}
