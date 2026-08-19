import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chapter.dart';
import '../models/manga.dart';

/// Small on-device cache for source mappings and chapter metadata.
///
/// Only metadata is persisted. Manga page images remain on the source sites
/// and are requested by the reader when a chapter is opened.
class ChapterIndexCache {
  ChapterIndexCache({Future<SharedPreferences>? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance() {
    // Keep this fallback for tests/alternate entrypoints. Normal app startup
    // explicitly awaits [warmGlobalSummaries] before runApp.
    unawaited(_bootstrapSummaries());
  }

  final Future<SharedPreferences> _preferences;

  // v6 invalidates all earlier partial/wrong source mappings and indexes.
  static const _version = 6;
  static const _chapterPrefix = 'tsuki.chapterIndex.v6.';
  static const _mappingPrefix = 'tsuki.sourceMapping.v10.';
  static const _checkedPrefix = 'tsuki.chapterChecked.v6.';
  static const _deepCheckedPrefix = 'tsuki.chapterDeepChecked.v6.';
  static const _summaryPrefix = 'tsuki.chapterSummary.v6.';

  /// Warm the tiny source-verified chapter summaries before the first frame.
  /// This is what makes the chapter chip instantaneous for previously-seen
  /// titles: no chapter-list JSON decoding and no website request is needed.
  static Future<void> warmGlobalSummaries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _loadSummariesFromPreferences(prefs);
    } catch (_) {
      // A cache warm-up failure must never prevent app startup.
    }
  }

  Future<void> _bootstrapSummaries() async {
    try {
      _loadSummariesFromPreferences(await _preferences);
    } catch (_) {
      // SharedPreferences startup failure must never block the app.
    }
  }

  static void _loadSummariesFromPreferences(SharedPreferences prefs) {
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_summaryPrefix)) continue;

      // Normal-mode summaries remain compatible, but adult summaries from
      // V6-V8 may have been produced by the broken adult resolver. Ignore
      // those old adult keys during startup so they cannot repopulate the
      // global registry before the V11 adult index is checked.
      final cacheKey = key.substring(_summaryPrefix.length);
      if (cacheKey.contains('|adult:') &&
          !cacheKey.endsWith('|adult:false') &&
          !cacheKey.endsWith('|adult:v11')) {
        continue;
      }

      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final value = jsonDecode(raw);
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        if (map['version'] != _version) continue;

        final mangaId = map['mangaId']?.toString();
        final count = (map['count'] as num?)?.toInt();
        final latestNumber = (map['latestNumber'] as num?)?.toDouble();
        if (mangaId == null || mangaId.isEmpty || count == null || count < 0) {
          continue;
        }
        MangaChapterRegistry.remember(
          mangaId,
          count,
          latestNumber: latestNumber,
        );
      } catch (_) {
        // Ignore one corrupt summary; the full index can recreate it.
      }
    }
  }

  /// Persist only the lightweight verified latest-number summary.
  ///
  /// This is used by Search/Discover cards so they can learn a manga's latest
  /// chapter without downloading its full chapter index first.
  Future<void> writeSummary(
    String cacheKey, {
    required String mangaId,
    required int indexCount,
    required double? latestNumber,
  }) async {
    if (mangaId.trim().isEmpty || indexCount < 0) return;
    if (latestNumber != null &&
        (!latestNumber.isFinite || latestNumber < 0 || latestNumber > 20000)) {
      return;
    }

    final prefs = await _preferences;
    MangaChapterRegistry.remember(
      mangaId,
      indexCount,
      latestNumber: latestNumber,
    );
    await prefs.setString(
      '$_summaryPrefix$cacheKey',
      jsonEncode(<String, Object?>{
        'version': _version,
        'mangaId': mangaId,
        'count': indexCount,
        'latestNumber': latestNumber,
      }),
    );
  }

  Future<List<CanonicalChapter>?> readChapters(String cacheKey) async {
    final prefs = await _preferences;
    final raw = prefs.getString('$_chapterPrefix$cacheKey');
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _version ||
          decoded['chapters'] is! List) {
        await _forgetSummary(prefs, cacheKey);
        return null;
      }

      final byKey = <String, CanonicalChapter>{};
      for (final rawChapter in decoded['chapters'] as List) {
        if (rawChapter is! Map) continue;
        final chapter = _chapterFromJson(Map<String, dynamic>.from(rawChapter));
        if (chapter == null || !chapter.hasDirectlyReadableCopy) continue;

        final number = chapter.number;
        if (number != null &&
            (!number.isFinite || number < 0 || number > 20000)) {
          continue;
        }

        final key = number == null
            ? 'special:${chapter.id}'
            : 'number:${_numberLabel(number)}';
        byKey[key] = chapter;
      }

      final chapters = byKey.values.toList()..sort(_chapterOrder);
      if (chapters.isEmpty) {
        await _forgetSummary(prefs, cacheKey);
        return null;
      }

      _rememberSummary(cacheKey, chapters);
      return chapters;
    } catch (_) {
      await prefs.remove('$_chapterPrefix$cacheKey');
      await _forgetSummary(prefs, cacheKey);
      return null;
    }
  }

  Future<void> _forgetSummary(SharedPreferences prefs, String cacheKey) async {
    await prefs.remove('$_summaryPrefix$cacheKey');
    final mangaId = _mangaIdFromCacheKey(cacheKey);
    if (mangaId.isNotEmpty) MangaChapterRegistry.remove(mangaId);
  }

  Future<void> writeChapters(
    String cacheKey,
    List<CanonicalChapter> chapters, {
    bool markChecked = false,
    bool markDeepChecked = false,
  }) async {
    if (chapters.isEmpty) return;

    final clean = chapters
        .where((chapter) {
          final number = chapter.number;
          return chapter.sourceCopies.isNotEmpty &&
              chapter.hasDirectlyReadableCopy &&
              (number == null ||
                  (number.isFinite && number >= 0 && number <= 20000));
        })
        .toList(growable: false);

    if (clean.isEmpty) return;

    final prefs = await _preferences;
    final payload = <String, Object?>{
      'version': _version,
      'chapters': clean.map(_chapterToJson).toList(growable: false),
    };

    await prefs.setString('$_chapterPrefix$cacheKey', jsonEncode(payload));
    await _writeSummary(prefs, cacheKey, clean);

    final now = DateTime.now().millisecondsSinceEpoch;
    if (markChecked) {
      await prefs.setInt('$_checkedPrefix$cacheKey', now);
    }
    if (markDeepChecked) {
      await prefs.setInt('$_deepCheckedPrefix$cacheKey', now);
    }
  }

  Future<void> _writeSummary(
    SharedPreferences prefs,
    String cacheKey,
    List<CanonicalChapter> chapters,
  ) async {
    final mangaId = _mangaIdFromCacheKey(cacheKey);
    if (mangaId.isEmpty || chapters.isEmpty) return;

    final summary = _summaryFor(chapters);
    MangaChapterRegistry.rememberSummary(mangaId, summary);

    await prefs.setString(
      '$_summaryPrefix$cacheKey',
      jsonEncode(<String, Object?>{
        'version': _version,
        'mangaId': mangaId,
        'count': summary.indexCount,
        'latestNumber': summary.latestNumber,
      }),
    );
  }

  void _rememberSummary(String cacheKey, List<CanonicalChapter> chapters) {
    final mangaId = _mangaIdFromCacheKey(cacheKey);
    if (mangaId.isEmpty || chapters.isEmpty) return;
    MangaChapterRegistry.rememberSummary(mangaId, _summaryFor(chapters));
  }

  MangaChapterSummary _summaryFor(List<CanonicalChapter> chapters) {
    double? latestNumber;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number == null || !number.isFinite || number < 0) continue;
      if (latestNumber == null || number > latestNumber) latestNumber = number;
    }
    return MangaChapterSummary(
      indexCount: chapters.length,
      latestNumber: latestNumber,
    );
  }

  Future<void> markChecked(String cacheKey, {bool deep = false}) async {
    final prefs = await _preferences;
    final now = DateTime.now().millisecondsSinceEpoch;
    await prefs.setInt('$_checkedPrefix$cacheKey', now);
    if (deep) {
      await prefs.setInt('$_deepCheckedPrefix$cacheKey', now);
    }
  }

  Future<String?> readMapping(String mappingKey) async {
    final prefs = await _preferences;
    final value = prefs.getString('$_mappingPrefix$mappingKey');
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<void> writeMapping(String mappingKey, String sourceMangaId) async {
    final value = sourceMangaId.trim();
    if (value.isEmpty) return;
    final prefs = await _preferences;
    await prefs.setString('$_mappingPrefix$mappingKey', value);
  }

  Future<void> removeMapping(String mappingKey) async {
    final prefs = await _preferences;
    await prefs.remove('$_mappingPrefix$mappingKey');
  }

  Future<bool> isStale(
    String cacheKey,
    Duration maxAge, {
    bool deep = false,
  }) async {
    final prefs = await _preferences;
    final prefix = deep ? _deepCheckedPrefix : _checkedPrefix;
    final value = prefs.getInt('$prefix$cacheKey');
    if (value == null) return true;

    final checked = DateTime.fromMillisecondsSinceEpoch(value);
    return DateTime.now().difference(checked) >= maxAge;
  }

  Map<String, Object?> _chapterToJson(CanonicalChapter chapter) => {
    'id': chapter.id,
    'number': chapter.number,
    'title': chapter.title,
    'publishedAt': chapter.publishedAt.millisecondsSinceEpoch,
    'sourceCopies': chapter.sourceCopies
        .map(
          (copy) => <String, Object?>{
            'sourceId': copy.sourceId,
            'chapterId': copy.chapterId,
            'reliability': copy.reliability,
            'publishedAt': copy.publishedAt.millisecondsSinceEpoch,
            'attribution': copy.attribution,
            'externalUrl': copy.externalUrl,
          },
        )
        .toList(growable: false),
  };

  CanonicalChapter? _chapterFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final title = json['title']?.toString();
    final rawCopies = json['sourceCopies'];
    if (id == null || id.isEmpty || title == null || rawCopies is! List) {
      return null;
    }

    final copies = <ChapterSourceCopy>[];
    for (final rawCopy in rawCopies) {
      if (rawCopy is! Map) continue;
      final value = Map<String, dynamic>.from(rawCopy);
      final sourceId = value['sourceId']?.toString();
      final chapterId = value['chapterId']?.toString();
      final reliability = (value['reliability'] as num?)?.toDouble();
      if (sourceId == null ||
          sourceId.isEmpty ||
          chapterId == null ||
          chapterId.isEmpty ||
          reliability == null) {
        continue;
      }

      copies.add(
        ChapterSourceCopy(
          sourceId: sourceId,
          chapterId: chapterId,
          reliability: reliability,
          publishedAt: _date(value['publishedAt']),
          attribution: value['attribution']?.toString(),
          externalUrl: value['externalUrl']?.toString(),
        ),
      );
    }

    if (copies.isEmpty) return null;
    copies.sort((a, b) => b.reliability.compareTo(a.reliability));

    return CanonicalChapter(
      id: id,
      number: (json['number'] as num?)?.toDouble(),
      title: title,
      publishedAt: _date(json['publishedAt']),
      sourceCopies: copies,
    );
  }

  DateTime _date(dynamic value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  int _chapterOrder(CanonicalChapter a, CanonicalChapter b) {
    final left = a.number;
    final right = b.number;
    if (left != null && right != null) return left.compareTo(right);
    if (left != null) return -1;
    if (right != null) return 1;
    final byDate = a.publishedAt.compareTo(b.publishedAt);
    return byDate != 0 ? byDate : a.title.compareTo(b.title);
  }

  String _mangaIdFromCacheKey(String cacheKey) {
    final marker = cacheKey.indexOf('|adult:');
    return marker < 0 ? cacheKey : cacheKey.substring(0, marker);
  }

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
