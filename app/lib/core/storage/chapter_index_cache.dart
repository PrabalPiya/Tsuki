import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chapter.dart';
import '../models/manga.dart';

/// Small session cache for source mappings and chapter metadata.
///
/// Runtime app data stays in memory. Manga page images remain on the source
/// sites and are requested by the reader when a chapter is opened.
class ChapterIndexCache {
  ChapterIndexCache({Future<SharedPreferences>? preferences})
    : _preferences = preferences {
    // Tests can inject preferences to exercise legacy decoding, but runtime
    // app data stays in memory and does not touch device storage.
    unawaited(
      preferences == null ? Future<void>.value() : _bootstrapSummaries(),
    );
  }

  final Future<SharedPreferences>? _preferences;
  final Map<String, String> _stringMemory = {};
  final Map<String, int> _intMemory = {};

  // v6 invalidates all earlier partial/wrong source mappings and indexes.
  static const _version = 6;
  static const _chapterPrefix = 'tsuki.chapterIndex.v6.';
  static const _mappingPrefix = 'tsuki.sourceMapping.release1.';
  static const _checkedPrefix = 'tsuki.chapterChecked.v6.';
  static const _deepCheckedPrefix = 'tsuki.chapterDeepChecked.v6.';
  static const _summaryPrefix = 'tsuki.chapterSummary.v6.';
  static Future<void>? _globalSummaryWarmup;

  /// Warm the tiny source-verified chapter summaries before the first frame.
  /// This is what makes the chapter chip instantaneous for previously-seen
  /// titles: no chapter-list JSON decoding and no website request is needed.
  static Future<void> warmGlobalSummaries() {
    return _globalSummaryWarmup ??= _warmGlobalSummaries().whenComplete(() {
      _globalSummaryWarmup = null;
    });
  }

  static Future<void> _warmGlobalSummaries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _loadSummariesFromPreferences(prefs);
    } catch (_) {
      // A cache warm-up failure must never prevent app startup.
    }
  }

  Future<void> _bootstrapSummaries() async {
    try {
      final preferences = _preferences;
      if (preferences != null) _loadSummariesFromPreferences(await preferences);
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
      // global registry before the release adult index is checked.
      final cacheKey = key.substring(_summaryPrefix.length);
      if (cacheKey.contains('|adult:') &&
          !cacheKey.endsWith('|adult:false') &&
          !cacheKey.endsWith('|adult:release1')) {
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

  Future<List<CanonicalChapter>?> readChapters(String cacheKey) async {
    final raw = await _readString('$_chapterPrefix$cacheKey');
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != _version ||
          decoded['chapters'] is! List) {
        await _forgetSummary(cacheKey);
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
        await _forgetSummary(cacheKey);
        return null;
      }

      _rememberSummary(cacheKey, chapters);
      return chapters;
    } catch (_) {
      await _remove('$_chapterPrefix$cacheKey');
      await _forgetSummary(cacheKey);
      return null;
    }
  }

  Future<void> _forgetSummary(String cacheKey) async {
    await _remove('$_summaryPrefix$cacheKey');
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

    final payload = <String, Object?>{
      'version': _version,
      'chapters': clean.map(_chapterToJson).toList(growable: false),
    };

    await _writeString('$_chapterPrefix$cacheKey', jsonEncode(payload));
    await _writeSummary(cacheKey, clean);

    final now = DateTime.now().millisecondsSinceEpoch;
    if (markChecked) {
      await _writeInt('$_checkedPrefix$cacheKey', now);
    }
    if (markDeepChecked) {
      await _writeInt('$_deepCheckedPrefix$cacheKey', now);
    }
  }

  Future<void> _writeSummary(
    String cacheKey,
    List<CanonicalChapter> chapters,
  ) async {
    final mangaId = _mangaIdFromCacheKey(cacheKey);
    if (mangaId.isEmpty || chapters.isEmpty) return;

    final summary = _summaryFor(chapters);
    MangaChapterRegistry.rememberSummary(mangaId, summary);

    await writeSummary(mangaId, summary, cacheKey: cacheKey);
  }

  /// Persists only the tiny latest-chapter summary. Runtime chapter indexes
  /// can stay memory-only while Home/Search still have an immediate label on
  /// the next launch.
  Future<void> writeSummary(
    String mangaId,
    MangaChapterSummary summary, {
    String? cacheKey,
  }) async {
    if (mangaId.trim().isEmpty) return;
    MangaChapterRegistry.rememberSummary(mangaId, summary);

    final encoded = jsonEncode(<String, Object?>{
      'version': _version,
      'mangaId': mangaId,
      'count': summary.indexCount,
      'latestNumber': summary.latestNumber,
    });
    final key = '$_summaryPrefix${cacheKey ?? '$mangaId|safe'}';
    final preferences = _preferences;
    if (preferences != null) {
      await (await preferences).setString(key, encoded);
      return;
    }
    await (await SharedPreferences.getInstance()).setString(key, encoded);
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
    final now = DateTime.now().millisecondsSinceEpoch;
    await _writeInt('$_checkedPrefix$cacheKey', now);
    if (deep) {
      await _writeInt('$_deepCheckedPrefix$cacheKey', now);
    }
  }

  Future<String?> readMapping(String mappingKey) async {
    final value = await _readString('$_mappingPrefix$mappingKey');
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  Future<void> writeMapping(String mappingKey, String sourceMangaId) async {
    final value = sourceMangaId.trim();
    if (value.isEmpty) return;
    await _writeString('$_mappingPrefix$mappingKey', value);
  }

  Future<void> removeMapping(String mappingKey) async {
    await _remove('$_mappingPrefix$mappingKey');
  }

  Future<bool> isStale(
    String cacheKey,
    Duration maxAge, {
    bool deep = false,
  }) async {
    final prefix = deep ? _deepCheckedPrefix : _checkedPrefix;
    final value = await _readInt('$prefix$cacheKey');
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
    final adultMarker = cacheKey.indexOf('|adult:');
    final safeMarker = cacheKey.indexOf('|safe');
    final markers = [adultMarker, safeMarker].where((value) => value >= 0);
    if (markers.isEmpty) return cacheKey;
    return cacheKey.substring(0, markers.reduce((a, b) => a < b ? a : b));
  }

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  Future<String?> _readString(String key) async {
    final preferences = _preferences;
    if (preferences == null) return _stringMemory[key];
    return (await preferences).getString(key);
  }

  Future<void> _writeString(String key, String value) async {
    final preferences = _preferences;
    if (preferences == null) {
      _stringMemory[key] = value;
      return;
    }
    await (await preferences).setString(key, value);
  }

  Future<int?> _readInt(String key) async {
    final preferences = _preferences;
    if (preferences == null) return _intMemory[key];
    return (await preferences).getInt(key);
  }

  Future<void> _writeInt(String key, int value) async {
    final preferences = _preferences;
    if (preferences == null) {
      _intMemory[key] = value;
      return;
    }
    await (await preferences).setInt(key, value);
  }

  Future<void> _remove(String key) async {
    final preferences = _preferences;
    if (preferences == null) {
      _stringMemory.remove(key);
      _intMemory.remove(key);
      return;
    }
    await (await preferences).remove(key);
  }
}
