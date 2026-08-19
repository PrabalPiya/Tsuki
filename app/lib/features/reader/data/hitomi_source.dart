import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/models/chapter.dart';
import '../../../core/models/manga.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/source_failure.dart';
import 'chapter_number_parser.dart';
import 'manga_source.dart';
import 'source_matching.dart';

/// Conservative adult-only Hitomi fallback.
///
/// Hitomi is gallery-oriented rather than a serialized manga API. Tsuki only
/// accepts strong canonical-title matches. Explicit chapter labels are mapped
/// to numbered chapters; unnumbered exact/volume galleries remain special
/// readable entries instead of being assigned invented chapter numbers.
class HitomiSource implements MangaSource {
  HitomiSource({Dio? client})
    : _client =
          client ??
          createHttpClient(
            baseUrl: 'https://ltn.gold-usergeneratedcontent.net',
          );

  static const _domain = 'ltn.gold-usergeneratedcontent.net';
  static const _maxNodeSize = 464;
  static const _branchCount = 16;
  static const _maxCandidateIds = 48;
  static const _maxGalleryFetches = 28;

  final Dio _client;
  String? _tagIndexVersion;
  String? _galleriesIndexVersion;
  DateTime? _versionLoadedAt;
  _HitomiGg? _gg;
  DateTime? _ggLoadedAt;

  @override
  String get id => 'hitomi';

  @override
  String get displayName => 'Hitomi';

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(
    search: true,
    details: true,
    chapters: true,
    pages: true,
    updates: true,
  );

  @override
  Set<String> get allowedImageHosts => const <String>{};

  @override
  Future<List<Manga>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const <Manga>[];

    final ids = await _searchIds(trimmed);
    final infos = await _fetchInfos(ids.take(18));
    return infos
        .where(_isEnglish)
        .map(
          (info) => Manga(
            id: 'hitomi:${info.id}',
            title: info.title,
            aliases: [if (info.japaneseTitle.isNotEmpty) info.japaneseTitle],
            coverUrl: '',
            synopsis: '',
            status: MangaStatus.unknown,
            chapterCount: 0,
            isAdult: true,
            format: MangaFormat.manga,
            genres: info.tags.take(8).toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  Future<String?> findConservativeMatch(Manga canonical) async {
    final payload = <String, Object?>{
      'title': canonical.title,
      'aliases': canonical.aliases.take(8).toList(growable: false),
    };
    final matches = await _matchingGalleries(canonical, maxFetches: 16);
    if (matches.isEmpty) return null;
    return Uri.encodeComponent(jsonEncode(payload));
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async {
    final canonical = _canonicalFromSourceId(sourceMangaId);
    if (canonical == null) return null;
    final matches = await _matchingGalleries(canonical, maxFetches: 12);
    if (matches.isEmpty) return null;
    final first = matches.first.info;
    return Manga(
      id: 'hitomi:$sourceMangaId',
      title: canonical.title,
      aliases: canonical.aliases,
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.unknown,
      chapterCount: 0,
      isAdult: true,
      format: MangaFormat.manga,
      genres: first.tags.take(8).toList(growable: false),
    );
  }

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async {
    final canonical = _canonicalFromSourceId(sourceMangaId);
    if (canonical == null) return const <CanonicalChapter>[];

    final matches = await _matchingGalleries(
      canonical,
      maxFetches: _maxGalleryFetches,
    );
    if (matches.isEmpty) return const <CanonicalChapter>[];

    final values = <CanonicalChapter>[];
    for (final match in matches) {
      final info = match.info;
      final title = _visibleGalleryTitle(info, canonical.title);
      final number =
          _explicitChapterNumber(info.title) ??
          _suffixChapterNumber(canonical, info.title);
      final published =
          DateTime.tryParse(info.date) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final safeTitle = title.isEmpty
          ? (number == null
                ? 'Full gallery'
                : 'Chapter ${ChapterNumberParser.label(number)}')
          : title;
      final key = number == null
          ? 'special:hitomi:${info.id}'
          : 'number:${ChapterNumberParser.label(number)}';

      values.add(
        CanonicalChapter(
          id: 'chapter:$key',
          number: number,
          title: safeTitle,
          publishedAt: published,
          sourceCopies: <ChapterSourceCopy>[
            ChapterSourceCopy(
              sourceId: id,
              chapterId: info.id.toString(),
              reliability: .48,
              publishedAt: published,
              attribution: 'Hitomi',
            ),
          ],
        ),
      );
    }

    values.sort((a, b) {
      final left = a.number;
      final right = b.number;
      if (left != null && right != null) return left.compareTo(right);
      if (left != null) return -1;
      if (right != null) return 1;
      return a.publishedAt.compareTo(b.publishedAt);
    });
    return values;
  }

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async {
    final chapters = await getChapters(sourceMangaId);
    CanonicalChapter? latestNumbered;
    CanonicalChapter? latestDated;
    for (final chapter in chapters) {
      if (chapter.number != null &&
          (latestNumbered == null ||
              chapter.number! > (latestNumbered.number ?? -1))) {
        latestNumbered = chapter;
      }
      if (latestDated == null ||
          chapter.publishedAt.isAfter(latestDated.publishedAt)) {
        latestDated = chapter;
      }
    }
    return latestNumbered ?? latestDated;
  }

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) async {
    final galleryId = int.tryParse(sourceChapterId);
    if (galleryId == null) {
      throw const SourceFailure('Invalid Hitomi gallery.', retryable: false);
    }
    final info = await _galleryInfo(galleryId);
    if (info.files.isEmpty) {
      throw const SourceFailure('Hitomi gallery has no readable pages.');
    }

    final gg = await _loadGg();
    final urls = <String>[];
    for (final file in info.files) {
      final hash = file.hash.toLowerCase();
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) continue;
      final path = '${gg.b}${_hashPathNumber(hash)}/$hash';
      final m = gg.m(_hashPathNumber(hash));
      if (file.hasWebp) {
        urls.add('https://w${1 + m}.gold-usergeneratedcontent.net/$path.webp');
      } else {
        final ext = file.name.contains('.')
            ? file.name.split('.').last.toLowerCase()
            : 'jpg';
        urls.add('https://${1 + m}.gold-usergeneratedcontent.net/$path.$ext');
      }
    }

    if (urls.isEmpty) {
      throw const SourceFailure('Hitomi gallery pages are unavailable.');
    }
    return ChapterPages(chapterId: sourceChapterId, sourceId: id, urls: urls);
  }

  Future<List<_HitomiMatch>> _matchingGalleries(
    Manga canonical, {
    required int maxFetches,
  }) async {
    final ids = <int>{};
    for (final query
        in <String>{canonical.title, ...canonical.aliases}
            .map((value) => value.trim())
            .where((value) => value.length >= 2)
            .take(6)) {
      try {
        ids.addAll(await _searchIds(query));
      } catch (_) {
        // Another alias can still work.
      }
      if (ids.length >= _maxCandidateIds) break;
    }

    final infos = await _fetchInfos(ids.take(maxFetches));
    final matches = <_HitomiMatch>[];
    for (final info in infos) {
      if (!_isEnglish(info)) continue;
      final score = _matchScore(canonical, info);
      if (score < .80) continue;
      matches.add(_HitomiMatch(info, score));
    }
    matches.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      return b.info.id.compareTo(a.info.id);
    });
    return matches;
  }

  double _matchScore(Manga canonical, _HitomiGallery info) {
    final expected = <String>{canonical.title, ...canonical.aliases};
    final actual = <String>{info.title, info.japaneseTitle};
    var best = 0.0;

    for (final left in expected) {
      final expectedNormalized = SourceMatching.normalize(left);
      if (expectedNormalized.isEmpty) continue;
      final expectedTokens = SourceMatching.tokens(left);

      for (final right in actual) {
        if (right.trim().isEmpty) continue;
        final actualNormalized = SourceMatching.normalize(right);
        final actualTokens = SourceMatching.tokens(right);
        var score = SourceMatching.similarity(left, right);

        // Hitomi commonly stores one gallery per chapter/volume, so the
        // gallery title may be `Series Name Chapter 12` rather than exactly
        // the AniList title. A full multi-token canonical title appearing in
        // that gallery title is strong evidence, while still avoiding loose
        // one-word substring matches.
        if (expectedTokens.length >= 2 &&
            expectedTokens.every(actualTokens.contains)) {
          score = score < .94 ? .94 : score;
        } else if (actualNormalized == expectedNormalized ||
            actualNormalized.startsWith('$expectedNormalized chapter ') ||
            actualNormalized.startsWith('$expectedNormalized ch ') ||
            actualNormalized.startsWith('$expectedNormalized volume ') ||
            actualNormalized.startsWith('$expectedNormalized vol ')) {
          score = score < .98 ? .98 : score;
        }

        if (score > best) best = score;
      }
    }
    return best;
  }

  bool _isEnglish(_HitomiGallery info) {
    final language = info.language.toLowerCase().trim();
    return language.isEmpty || language == 'english' || language == 'en';
  }

  double? _explicitChapterNumber(String value) {
    return ChapterNumberParser.parseVisibleLabel(value);
  }

  double? _suffixChapterNumber(Manga canonical, String galleryTitle) {
    final expectedNames = <String>{
      canonical.title,
      ...canonical.aliases,
    }.map(SourceMatching.normalize).where((value) => value.isNotEmpty);
    final actual = SourceMatching.normalize(galleryTitle);
    for (final expected in expectedNames) {
      if (!actual.startsWith(expected)) continue;
      final suffix = actual.substring(expected.length).trim();
      if (RegExp(
        r'^(?:vol|volume)\s+\d',
        caseSensitive: false,
      ).hasMatch(suffix)) {
        return null;
      }
      final match = RegExp(r'^(?:chapter\s+|ch\s+)?(\d+(?:\.\d+)?)$')
          .firstMatch(suffix);
      final number = double.tryParse(match?.group(1) ?? '');
      if (number != null && number >= 0 && number <= 20000) return number;
    }
    return null;
  }

  String _visibleGalleryTitle(_HitomiGallery info, String canonicalTitle) {
    final raw = info.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (raw.isEmpty) return 'Full gallery';
    if (SourceMatching.normalize(raw) ==
        SourceMatching.normalize(canonicalTitle)) {
      return 'Full gallery';
    }
    return raw;
  }

  Manga? _canonicalFromSourceId(String sourceMangaId) {
    try {
      final decoded = Uri.decodeComponent(sourceMangaId);
      final json = jsonDecode(decoded);
      if (json is! Map) return null;
      final title = json['title']?.toString().trim() ?? '';
      if (title.isEmpty) return null;
      return Manga(
        id: 'hitomi:canonical',
        title: title,
        aliases: (json['aliases'] as List? ?? const <Object>[])
            .whereType<Object>()
            .map((value) => value.toString())
            .toList(growable: false),
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.unknown,
        chapterCount: 0,
        isAdult: true,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _searchIds(String query) async {
    final positiveTerms = query
        .toLowerCase()
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .take(8)
        .toList(growable: false);
    if (positiveTerms.isEmpty) return const <int>[];

    Set<int>? result;
    for (final term in positiveTerms) {
      final ids = await _galleryIdsForTerm(term);
      result = result == null ? ids : result.intersection(ids);
      if (result.isEmpty) break;
    }
    final values = (result ?? const <int>{}).toList(growable: false)
      ..sort((a, b) => b.compareTo(a));
    return values.take(_maxCandidateIds).toList(growable: false);
  }

  Future<Set<int>> _galleryIdsForTerm(String term) async {
    await _loadVersions();
    final version = _galleriesIndexVersion;
    if (version == null || version.isEmpty) return <int>{};
    final key = sha256.convert(utf8.encode(term)).bytes.sublist(0, 4);
    final root = await _nodeAt('galleries', 0);
    if (root == null) return <int>{};
    final data = await _bSearch('galleries', key, root);
    if (data == null) return <int>{};

    if (data.length <= 0 || data.length > 100000000) return <int>{};
    final bytes = await _rangeBytes(
      'https://$_domain/galleriesindex/galleries.$version.data',
      data.offset,
      data.offset + data.length,
    );
    if (bytes.length < 4) return <int>{};
    final view = ByteData.sublistView(Uint8List.fromList(bytes));
    final count = view.getInt32(0, Endian.big);
    if (count <= 0 || count > 10000000) return <int>{};
    final ids = <int>{};
    var offset = 4;
    for (var i = 0; i < count && offset + 4 <= bytes.length; i++) {
      ids.add(view.getInt32(offset, Endian.big));
      offset += 4;
    }
    return ids;
  }

  Future<_HitomiDataRef?> _bSearch(
    String field,
    List<int> key,
    _HitomiNode node,
  ) async {
    if (node.keys.isEmpty) return null;
    var where = node.keys.length;
    var exact = false;
    for (var i = 0; i < node.keys.length; i++) {
      final cmp = _compareBytes(key, node.keys[i]);
      if (cmp <= 0) {
        where = i;
        exact = cmp == 0;
        break;
      }
    }
    if (exact) return node.datas[where];
    if (node.subNodes.every((value) => value == 0)) return null;
    if (where >= node.subNodes.length || node.subNodes[where] == 0) return null;
    final next = await _nodeAt(field, node.subNodes[where]);
    if (next == null) return null;
    return _bSearch(field, key, next);
  }

  Future<_HitomiNode?> _nodeAt(String field, int address) async {
    await _loadVersions();
    final version = field == 'galleries'
        ? _galleriesIndexVersion
        : _tagIndexVersion;
    if (version == null || version.isEmpty || address < 0) return null;
    final dir = field == 'galleries' ? 'galleriesindex' : 'tagindex';
    final url = 'https://$_domain/$dir/$field.$version.index';
    final bytes = await _rangeBytes(url, address, address + _maxNodeSize);
    return _decodeNode(bytes);
  }

  _HitomiNode? _decodeNode(List<int> bytes) {
    try {
      final view = ByteData.sublistView(Uint8List.fromList(bytes));
      var offset = 0;
      int readI32() {
        final value = view.getInt32(offset, Endian.big);
        offset += 4;
        return value;
      }

      int readI64() {
        final value = view.getInt64(offset, Endian.big);
        offset += 8;
        return value;
      }

      final keyCount = readI32();
      if (keyCount < 0 || keyCount > 64) return null;
      final keys = <List<int>>[];
      for (var i = 0; i < keyCount; i++) {
        final size = readI32();
        if (size <= 0 || size > 32 || offset + size > bytes.length) return null;
        keys.add(bytes.sublist(offset, offset + size));
        offset += size;
      }
      final dataCount = readI32();
      if (dataCount < 0 || dataCount > 64) return null;
      final datas = <_HitomiDataRef>[];
      for (var i = 0; i < dataCount; i++) {
        datas.add(_HitomiDataRef(readI64(), readI32()));
      }
      final subNodes = <int>[];
      for (var i = 0; i <= _branchCount && offset + 8 <= bytes.length; i++) {
        subNodes.add(readI64());
      }
      while (subNodes.length <= _branchCount) {
        subNodes.add(0);
      }
      return _HitomiNode(keys, datas, subNodes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadVersions() async {
    final now = DateTime.now();
    if (_galleriesIndexVersion != null &&
        _tagIndexVersion != null &&
        _versionLoadedAt != null &&
        now.difference(_versionLoadedAt!) < const Duration(minutes: 30)) {
      return;
    }
    final timestamp = now.millisecondsSinceEpoch;
    final galleries = await _client.get<String>(
      '/galleriesindex/version',
      queryParameters: <String, Object>{'_': timestamp},
      options: Options(responseType: ResponseType.plain),
    );
    final tags = await _client.get<String>(
      '/tagindex/version',
      queryParameters: <String, Object>{'_': timestamp},
      options: Options(responseType: ResponseType.plain),
    );
    _galleriesIndexVersion = galleries.data?.trim();
    _tagIndexVersion = tags.data?.trim();
    _versionLoadedAt = now;
  }

  Future<List<int>> _rangeBytes(String url, int start, int endExclusive) async {
    final response = await _client.get<List<int>>(
      url,
      options: Options(
        headers: <String, String>{'Range': 'bytes=$start-${endExclusive - 1}'},
        responseType: ResponseType.bytes,
      ),
    );
    return response.data ?? const <int>[];
  }

  Future<List<_HitomiGallery>> _fetchInfos(Iterable<int> ids) async {
    final futures = ids.map((galleryId) async {
      try {
        return await _galleryInfo(galleryId);
      } catch (_) {
        return null;
      }
    });
    final values = await Future.wait(futures);
    return values.whereType<_HitomiGallery>().toList(growable: false);
  }

  Future<_HitomiGallery> _galleryInfo(int galleryId) async {
    final response = await _client.get<String>(
      '/galleries/$galleryId.js',
      options: Options(responseType: ResponseType.plain),
    );
    var body = response.data ?? '';
    body = body.trim();
    if (body.startsWith('var galleryinfo = ')) {
      body = body.substring('var galleryinfo = '.length);
    }
    if (body.endsWith(';')) body = body.substring(0, body.length - 1);
    final raw = jsonDecode(body);
    if (raw is! Map) {
      throw const SourceFailure('Invalid Hitomi gallery data.');
    }
    return _HitomiGallery.fromJson(galleryId, Map<String, dynamic>.from(raw));
  }

  Future<_HitomiGg> _loadGg() async {
    final now = DateTime.now();
    if (_gg != null &&
        _ggLoadedAt != null &&
        now.difference(_ggLoadedAt!) < const Duration(minutes: 1)) {
      return _gg!;
    }
    final response = await _client.get<String>(
      '/gg.js',
      options: Options(responseType: ResponseType.plain),
    );
    final body = response.data ?? '';
    final defaultMatch = RegExp(r'var o = (\d)').firstMatch(body);
    final selectedMatch = RegExp(r'o = (\d); break;').firstMatch(body);
    final bMatch = RegExp(r"b: '(.+)'").firstMatch(body);
    final defaultM = int.tryParse(defaultMatch?.group(1) ?? '') ?? 0;
    final selectedM = int.tryParse(selectedMatch?.group(1) ?? '') ?? defaultM;
    final map = <int, int>{};
    for (final match in RegExp(r'case (\d+):').allMatches(body)) {
      final key = int.tryParse(match.group(1) ?? '');
      if (key != null) map[key] = selectedM;
    }
    _gg = _HitomiGg(defaultM, map, bMatch?.group(1) ?? '');
    _ggLoadedAt = now;
    return _gg!;
  }

  int _hashPathNumber(String hash) {
    if (hash.length < 3) return 0;
    final tail =
        '${hash.substring(hash.length - 1)}'
        '${hash.substring(hash.length - 3, hash.length - 1)}';
    return int.tryParse(tail, radix: 16) ?? 0;
  }

  int _compareBytes(List<int> left, List<int> right) {
    final top = left.length < right.length ? left.length : right.length;
    for (var i = 0; i < top; i++) {
      if (left[i] < right[i]) return -1;
      if (left[i] > right[i]) return 1;
    }
    if (left.length == right.length) return 0;
    return left.length < right.length ? -1 : 1;
  }
}

class _HitomiMatch {
  const _HitomiMatch(this.info, this.score);
  final _HitomiGallery info;
  final double score;
}

class _HitomiGallery {
  const _HitomiGallery({
    required this.id,
    required this.title,
    required this.japaneseTitle,
    required this.language,
    required this.date,
    required this.tags,
    required this.files,
  });

  final int id;
  final String title;
  final String japaneseTitle;
  final String language;
  final String date;
  final List<String> tags;
  final List<_HitomiFile> files;

  factory _HitomiGallery.fromJson(int fallbackId, Map<String, dynamic> json) {
    final tags = (json['tags'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((raw) => raw['tag']?.toString().trim() ?? '')
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final files = (json['files'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((raw) => _HitomiFile.fromJson(Map<String, dynamic>.from(raw)))
        .where((file) => file.hash.isNotEmpty)
        .toList(growable: false);
    return _HitomiGallery(
      id: int.tryParse(json['id']?.toString() ?? '') ?? fallbackId,
      title: json['title']?.toString().trim() ?? '',
      japaneseTitle: json['japanese_title']?.toString().trim() ?? '',
      language: json['language']?.toString().trim() ?? '',
      date: json['date']?.toString().trim() ?? '',
      tags: tags,
      files: files,
    );
  }
}

class _HitomiFile {
  const _HitomiFile({
    required this.hash,
    required this.name,
    required this.hasWebp,
  });
  final String hash;
  final String name;
  final bool hasWebp;

  factory _HitomiFile.fromJson(Map<String, dynamic> json) => _HitomiFile(
    hash: json['hash']?.toString().trim() ?? '',
    name: json['name']?.toString().trim() ?? '',
    hasWebp: int.tryParse(json['haswebp']?.toString() ?? '0') == 1,
  );
}

class _HitomiDataRef {
  const _HitomiDataRef(this.offset, this.length);
  final int offset;
  final int length;
}

class _HitomiNode {
  const _HitomiNode(this.keys, this.datas, this.subNodes);
  final List<List<int>> keys;
  final List<_HitomiDataRef> datas;
  final List<int> subNodes;
}

class _HitomiGg {
  const _HitomiGg(this.defaultM, this.map, this.b);
  final int defaultM;
  final Map<int, int> map;
  final String b;
  int m(int value) => map[value] ?? defaultM;
}
