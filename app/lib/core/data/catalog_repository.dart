import 'dart:async';

import '../config/app_config.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/chapter_index_cache.dart';

import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/comick_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangapill_source.dart';
import '../../features/reader/data/weebcentral_source.dart';
import '../../features/reader/data/webtoon_xyz_source.dart';
import '../../features/search/data/metadata_provider.dart';
import '../../shared/demo_catalog.dart';

class CatalogRepository {
  CatalogRepository({
    required AppConfig config,
    required MetadataProvider metadata,
    required MangaDexSource mangaDex,
    ComicKSource? comicK,
    MangaPillSource? mangaPill,
    WeebCentralSource? weebCentral,
    WebtoonXyzSource? webtoonXyz,
    AsuraSource? asura,
    ChapterIndexCache? chapterIndexCache,
  })  : _config = config,
        _metadata = metadata,
        _mangaDex = mangaDex,
        _comicK = comicK ?? ComicKSource(),
        _mangaPill = mangaPill ?? MangaPillSource(),
        _weebCentral = weebCentral ?? WeebCentralSource(),
        _webtoonXyz = webtoonXyz ?? WebtoonXyzSource(),
        _asura = asura ?? AsuraSource(),
        _indexCache = chapterIndexCache ?? ChapterIndexCache() {
    if (_config.useDemoData) {
      for (final manga in demoCatalog) {
        _cache[manga.id] = manga;
      }
    }
  }

  final AppConfig _config;
  final MetadataProvider _metadata;
  final MangaDexSource _mangaDex;
  final ComicKSource _comicK;
  final MangaPillSource _mangaPill;
  final WeebCentralSource _weebCentral;
  final WebtoonXyzSource _webtoonXyz;
  final AsuraSource _asura;
  final ChapterIndexCache _indexCache;

  final Map<String, Manga> _cache = {};
  final Map<String, List<CanonicalChapter>> _chapterCache = {};
  final Map<String, String> _sourceMatchCache = {};
  final Map<String, Future<List<CanonicalChapter>>> _refreshing = {};
  final Map<String, Future<void>> _summaryPriming = {};
  final StreamController<String> _chapterUpdateController =
      StreamController<String>.broadcast();

  static const _primaryTimeout = Duration(seconds: 14);
  static const _fallbackTimeout = Duration(seconds: 22);
  static const _quickRefreshAge = Duration(minutes: 10);
  static const _deepRefreshAge = Duration(hours: 6);

  Stream<String> get chapterUpdates => _chapterUpdateController.stream;

  List<Manga> get demoRankings =>
      _config.useDemoData ? demoCatalog : const <Manga>[];

  Manga? cached(String id) => _cache[id];

  void remember(Manga manga) {
    _cache[manga.id] = manga;
  }

  Future<List<Manga>> search(
    String query, {
    required bool includeAdult,
  }) async {
    if (query.trim().length < 2) return const [];

    try {
      final values = await _metadata.search(
        query.trim(),
        includeAdult: includeAdult,
      );
      for (final value in values) {
        _cache[value.id] = value;
      }
      final result = _dedupe(values);
      for (final manga in result.take(6)) {
        unawaited(
          primeChapterSummary(
            manga,
            allowAdult: includeAdult,
          ),
        );
      }
      return result;
    } catch (_) {
      if (!_config.useDemoData) rethrow;
      final normalized = query.toLowerCase();
      return demoCatalog
          .where((manga) => manga.title.toLowerCase().contains(normalized))
          .toList();
    }
  }

  Future<Manga?> details(String id) async {
    final value = _cache[id];
    if (value != null) return value;

    final loaded = await _metadata.getById(id);
    if (loaded != null) _cache[id] = loaded;
    return loaded;
  }

  /// Returns only an existing memory/on-device chapter index.
  /// It never performs a source request.
  Future<List<CanonicalChapter>?> localChapters(
    Manga manga, {
    bool allowAdult = false,
  }) async {
    if (manga.isAdult && !allowAdult) return const [];
    final cacheKey = _chapterCacheKey(manga, allowAdult);

    final memory = _chapterCache[cacheKey];
    if (memory != null && memory.isNotEmpty) return memory;

    final stored = await _indexCache.readChapters(cacheKey);
    if (stored == null || stored.isEmpty) return null;
    _rememberChapterIndex(manga, cacheKey, stored, notify: false);
    return stored;
  }

  /// Cache-first chapter loading.
  ///
  /// Once a manga has been seen, its local chapter index is returned
  /// immediately. Network refreshes happen after that and publish an update
  /// through [chapterUpdates]. On the first ever open, WeebCentral is tried
  /// first because it exposes a dedicated complete chapter-list endpoint.
  Future<List<CanonicalChapter>> chapters(
    Manga manga, {
    bool refresh = false,
    bool allowAdult = false,
  }) async {
    if (manga.isAdult && !allowAdult) return const [];

    if (manga.id.startsWith('demo:')) {
      final values = demoChapters(manga);
      _chapterCache[_chapterCacheKey(manga, allowAdult)] = values;
      return values;
    }

    if (refresh) {
      return refreshChapters(
        manga,
        allowAdult: allowAdult,
        force: true,
      );
    }

    final cacheKey = _chapterCacheKey(manga, allowAdult);
    final local = await localChapters(manga, allowAdult: allowAdult);
    if (local != null && local.isNotEmpty) {
      _scheduleRefreshIfStale(manga, cacheKey, allowAdult: allowAdult);
      return local;
    }

    // First-ever open: start each provider once. The first complete usable
    // source index is returned as soon as it arrives; slower providers keep
    // running and merge their missing chapters into the same cache. This avoids
    // the previous double-fetch (race once, then immediately fetch all again).
    return _loadInitialProgressively(
      manga,
      cacheKey,
      allowAdult: allowAdult,
    );
  }

  List<Future<List<CanonicalChapter>> Function()> _loadersFor(
    Manga manga, {
    required bool allowAdult,
  }) {
    if (manga.isAdult || allowAdult) {
      return <Future<List<CanonicalChapter>> Function()>[
        () => _loadWeebCentral(manga, allowAdult: allowAdult),
        () => _loadMangaDex(manga, allowAdult: allowAdult),
        () => _loadComicK(manga),
        () => _loadMangaPill(manga),
        () => _loadWebtoonXyz(manga).timeout(
              const Duration(seconds: 8),
              onTimeout: () => const <CanonicalChapter>[],
            ),
      ];
    }

    return <Future<List<CanonicalChapter>> Function()>[
      () => _loadWeebCentral(manga, allowAdult: allowAdult),
      () => _loadComicK(manga),
      () => _loadMangaDex(manga, allowAdult: allowAdult),
      () => _loadAsura(manga),
      () => _loadMangaPill(manga),
    ];
  }

  Future<List<CanonicalChapter>> _loadInitialProgressively(
    Manga manga,
    String cacheKey, {
    required bool allowAdult,
  }) {
    final loaders = _loadersFor(
      manga,
      allowAdult: allowAdult,
    );
    if (loaders.isEmpty) return Future.value(const <CanonicalChapter>[]);

    final first = Completer<List<CanonicalChapter>>();
    var firstWaitersRemaining = loaders.length;
    var rawRemaining = loaders.length;
    var aggregate = <CanonicalChapter>[];
    var persistChain = Future<void>.value();

    void mergeBatch(List<CanonicalChapter> rawBatch) {
      final batch = _sanitizeBatch(rawBatch);
      if (batch.isEmpty) return;

      aggregate = _mergeChapters(<CanonicalChapter>[...aggregate, ...batch]);
      final snapshot = List<CanonicalChapter>.unmodifiable(aggregate);

      // Update memory/UI synchronously. Disk writes are serialized so a slower
      // older write can never overwrite a newer, fuller index.
      _rememberChapterIndex(manga, cacheKey, snapshot, notify: true);
      persistChain = persistChain.then(
        (_) => _indexCache.writeChapters(cacheKey, snapshot),
      );

      if (!first.isCompleted) first.complete(snapshot);
    }

    void finishRaw() {
      rawRemaining--;
      if (rawRemaining != 0) return;
      persistChain = persistChain.then((_) async {
        await _indexCache.markChecked(cacheKey, deep: true);
      });
    }

    for (final loader in loaders) {
      Future<List<CanonicalChapter>> raw;
      try {
        raw = loader();
      } catch (_) {
        raw = Future<List<CanonicalChapter>>.value(const <CanonicalChapter>[]);
      }

      unawaited(
        raw.then(mergeBatch).catchError((_) {}).whenComplete(finishRaw),
      );

      // The timeout only bounds how long the UI waits for its *first* result.
      // It does not cancel or discard the real source harvest above.
      unawaited(
        raw.timeout(_fallbackTimeout, onTimeout: () => const <CanonicalChapter>[])
            .then((value) {
          final clean = _sanitizeBatch(value);
          if (clean.isNotEmpty && !first.isCompleted) {
            first.complete(_mergeChapters(clean));
          }
          firstWaitersRemaining--;
          if (firstWaitersRemaining == 0 && !first.isCompleted) {
            first.complete(aggregate);
          }
        }).catchError((_) {
          firstWaitersRemaining--;
          if (firstWaitersRemaining == 0 && !first.isCompleted) {
            first.complete(aggregate);
          }
        }),
      );
    }

    return first.future;
  }

  /// Resolve only the latest numbered chapter for a card that does not yet
  /// have a verified local summary. This is deliberately lighter than loading
  /// the complete chapter index and is deduplicated per manga.
  Future<void> primeChapterSummary(
    Manga manga, {
    bool allowAdult = false,
  }) async {
    if (manga.isAdult && !allowAdult) return;
    final existingSummary = MangaChapterRegistry.summaryFor(manga.id);
    if (existingSummary?.latestNumber != null) return;

    final cacheKey = _chapterCacheKey(manga, allowAdult);
    final active = _summaryPriming[cacheKey];
    if (active != null) return active;

    final future = () async {
      final probe = await _safeLatestPrimary(
        manga,
        allowAdult: allowAdult,
      );
      final latestNumber = probe?.chapter.number;
      if (latestNumber == null ||
          !latestNumber.isFinite ||
          latestNumber < 0 ||
          latestNumber > 20000) {
        return;
      }

      MangaChapterRegistry.remember(
        manga.id,
        0,
        latestNumber: latestNumber,
      );
      await _indexCache.writeSummary(
        cacheKey,
        mangaId: manga.id,
        indexCount: 0,
        latestNumber: latestNumber,
      );
      _chapterUpdateController.add(manga.id);
    }();

    _summaryPriming[cacheKey] = future;
    try {
      await future;
    } finally {
      if (identical(_summaryPriming[cacheKey], future)) {
        _summaryPriming.remove(cacheKey);
      }
    }
  }

  Future<List<CanonicalChapter>> refreshChapters(
    Manga manga, {
    bool allowAdult = false,
    bool force = false,
  }) async {
    if (manga.isAdult && !allowAdult) return const [];

    final cacheKey = _chapterCacheKey(manga, allowAdult);
    final active = _refreshing[cacheKey];
    if (active != null) return active;

    final future = _refreshChaptersInternal(
      manga,
      cacheKey,
      allowAdult: allowAdult,
      force: force,
    );
    _refreshing[cacheKey] = future;

    try {
      return await future;
    } finally {
      if (identical(_refreshing[cacheKey], future)) {
        _refreshing.remove(cacheKey);
      }
    }
  }

  Future<List<CanonicalChapter>> _refreshChaptersInternal(
    Manga manga,
    String cacheKey, {
    required bool allowAdult,
    required bool force,
  }) async {
    final existing =
        await localChapters(manga, allowAdult: allowAdult) ??
            const <CanonicalChapter>[];

    if (!force &&
        existing.isNotEmpty &&
        !await _indexCache.isStale(cacheKey, _quickRefreshAge)) {
      return existing;
    }

    final deep = force ||
        existing.isEmpty ||
        await _indexCache.isStale(
          cacheKey,
          _deepRefreshAge,
          deep: true,
        );

    // Normal refresh: probe a source that is actually appropriate for this
    // title. The previous build only checked WeebCentral, so adult manga that
    // existed only on ComicK/MangaDex/MangaPill could never discover updates
    // until a deep refresh.
    if (!deep && existing.isNotEmpty) {
      final probe = await _safeLatestPrimary(
        manga,
        allowAdult: allowAdult,
      );
      var result = existing;

      if (probe != null && _isNewerThanIndex(probe.chapter, existing)) {
        final fresh = await _safe(
          () => _loadSourceByName(
            manga,
            probe.source,
            allowAdult: allowAdult,
          ),
        );
        if (fresh.isNotEmpty) {
          result = _mergeChapters([...existing, ...fresh]);
        }
      }

      await _storeChapterIndex(
        manga,
        cacheKey,
        result,
        markChecked: true,
      );
      return result;
    }

    // Deep refresh: merge the strongest complete indexes. Adult titles use
    // providers that actually expose adult/general catalogues first.
    final loaders = _loadersFor(
      manga,
      allowAdult: allowAdult,
    );

    // Do not wrap a complete paginated source harvest in one global timeout.
    // Dio already applies a timeout to each individual HTTP request. A whole-
    // source timeout was truncating long manga and producing half chapter lists.
    final primaryBatches = await Future.wait(
      loaders.map((loader) => _safe(loader)),
    );

    final collected = <CanonicalChapter>[...existing];
    for (final batch in primaryBatches) {
      if (batch.isNotEmpty) collected.addAll(batch);
    }

    final merged = _mergeChapters(collected);
    final result = merged.isNotEmpty ? merged : existing;

    if (result.isNotEmpty) {
      await _storeChapterIndex(
        manga,
        cacheKey,
        result,
        markChecked: true,
        markDeepChecked: deep,
      );
    } else {
      await _indexCache.markChecked(cacheKey, deep: deep);
    }

    return result;
  }

  void _scheduleRefreshIfStale(
    Manga manga,
    String cacheKey, {
    required bool allowAdult,
  }) {
    unawaited(() async {
      if (!await _indexCache.isStale(cacheKey, _quickRefreshAge)) return;
      try {
        await refreshChapters(manga, allowAdult: allowAdult);
      } catch (_) {
        // A working local index must survive temporary source failures.
      }
    }());
  }


  Future<({String source, CanonicalChapter chapter})?>
      _safeLatestPrimary(
    Manga manga, {
    required bool allowAdult,
  }) {
    final sourceOrder = manga.isAdult || allowAdult
        ? const <String>[
            'weebcentral',
            'mangadex',
            'comick',
            'mangapill',
            'webtoonxyz',
          ]
        : const <String>['weebcentral', 'comick', 'mangadex', 'mangapill'];

    final completer =
        Completer<({String source, CanonicalChapter chapter})?>();
    var remaining = sourceOrder.length;

    if (remaining == 0) {
      completer.complete(null);
      return completer.future;
    }

    void finishedWithoutValue() {
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    }

    for (final source in sourceOrder) {
      unawaited(
        _latestFromSource(
          manga,
          source,
          allowAdult: allowAdult,
        ).timeout(_primaryTimeout).then((chapter) {
          if (chapter != null && !completer.isCompleted) {
            completer.complete((source: source, chapter: chapter));
          }
        }).catchError((_) {
          // Another source can still provide the summary.
        }).whenComplete(finishedWithoutValue),
      );
    }

    return completer.future;
  }

  Future<CanonicalChapter?> _latestFromSource(
    Manga manga,
    String sourceName, {
    required bool allowAdult,
  }) async {
    if (sourceName == 'mangadex') {
      final direct = manga.mangaDexId;
      final sourceId = direct != null && direct.isNotEmpty
          ? direct
          : await _resolveMapped(
              manga,
              sourceName: 'mangadex',
              resolver: () => _mangaDex.findConservativeMatch(
                manga,
                allowAdult: allowAdult,
              ),
            );
      if (sourceId == null) return null;
      return _latestChapterFrom(await _mangaDex.getChapters(sourceId));
    }

    if (sourceName == 'comick') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'comick',
        resolver: () => _comicK.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _comicK.getLatestChapter(sourceId);
    }

    if (sourceName == 'mangapill') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'mangapill',
        resolver: () => _mangaPill.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return _latestChapterFrom(await _mangaPill.getChapters(sourceId));
    }

    if (sourceName == 'weebcentral') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'weebcentral',
        resolver: () => _weebCentral.findConservativeMatch(
          manga,
          allowAdult: allowAdult,
        ),
      );
      if (sourceId == null) return null;
      return await _weebCentral.getLatestChapter(sourceId);
    }


    if (sourceName == 'webtoonxyz') {
      if (!allowAdult) return null;
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'webtoonxyz',
        resolver: () => _webtoonXyz.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _webtoonXyz.getLatestChapter(sourceId);
    }
    return null;
  }

  CanonicalChapter? _latestChapterFrom(List<CanonicalChapter> values) {
    CanonicalChapter? latestNumbered;
    CanonicalChapter? latestDated;

    for (final chapter in values) {
      final number = chapter.number;
      if (number != null &&
          number.isFinite &&
          number >= 0 &&
          (latestNumbered == null ||
              number > (latestNumbered.number ?? -1))) {
        latestNumbered = chapter;
      }

      if (latestDated == null ||
          chapter.publishedAt.isAfter(latestDated.publishedAt)) {
        latestDated = chapter;
      }
    }

    return latestNumbered ?? latestDated;
  }

  Future<List<CanonicalChapter>> _loadSourceByName(
    Manga manga,
    String sourceName, {
    required bool allowAdult,
  }) {
    return switch (sourceName) {
      'weebcentral' => _loadWeebCentral(
          manga,
          allowAdult: allowAdult,
        ),
      'comick' => _loadComicK(manga),
      'mangadex' => _loadMangaDex(
          manga,
          allowAdult: allowAdult,
        ),
      'mangapill' => _loadMangaPill(manga),
      'asura' => _loadAsura(manga),
      'webtoonxyz' => allowAdult
          ? _loadWebtoonXyz(manga)
          : Future.value(const <CanonicalChapter>[]),
      _ => Future.value(const <CanonicalChapter>[]),
    };
  }

  bool _isNewerThanIndex(
    CanonicalChapter candidate,
    List<CanonicalChapter> existing,
  ) {
    if (existing.isEmpty) return true;

    final candidateNumber = candidate.number;
    final latestNumber = _latestNumber(existing);
    if (candidateNumber != null) {
      if (latestNumber == null) return true;
      return candidateNumber > latestNumber;
    }

    var latestDate = DateTime.fromMillisecondsSinceEpoch(0);
    for (final chapter in existing) {
      if (chapter.publishedAt.isAfter(latestDate)) {
        latestDate = chapter.publishedAt;
      }
    }
    return candidate.publishedAt.isAfter(latestDate);
  }

  Future<List<CanonicalChapter>> _safe(
    Future<List<CanonicalChapter>> Function() operation, {
    Duration? timeout,
  }) async {
    try {
      final future = operation();
      final values = timeout == null ? await future : await future.timeout(timeout);
      return _sanitizeBatch(values);
    } catch (_) {
      return const [];
    }
  }

  List<CanonicalChapter> _sanitizeBatch(List<CanonicalChapter> values) {
    final result = <CanonicalChapter>[];
    for (final chapter in values) {
      final number = chapter.number;
      if (chapter.sourceCopies.isEmpty || !chapter.hasDirectlyReadableCopy) {
        continue;
      }
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }
      result.add(chapter);
    }
    return result;
  }

  Future<List<CanonicalChapter>> _loadMangaDex(
    Manga manga, {
    required bool allowAdult,
  }) async {
    final key = '${manga.id}|mangadex';
    final directId = manga.mangaDexId;

    if (directId != null && directId.isNotEmpty) {
      try {
        final directValues = await _mangaDex.getChapters(directId);
        if (directValues.isNotEmpty) {
          _sourceMatchCache[key] = directId;
          await _indexCache.writeMapping(key, directId);
          return directValues;
        }
      } catch (_) {
        // Stored MangaDex ids can become stale; fall through and rematch.
      }
      await _clearMapping(key);
    }

    final sourceId = await _resolveMapped(
      manga,
      sourceName: 'mangadex',
      resolver: () => _mangaDex.findConservativeMatch(
                manga,
                allowAdult: allowAdult,
              ),
    );
    if (sourceId == null) return const [];

    try {
      final values = await _mangaDex.getChapters(sourceId);
      if (values.isNotEmpty) {
        final existing = _cache[manga.id] ?? manga;
        _cache[manga.id] = existing.copyWith(mangaDexId: sourceId);
      }
      return values;
    } catch (_) {
      await _clearMapping(key);
      return const [];
    }
  }

  Future<List<CanonicalChapter>> _loadComicK(Manga manga) => _loadMappedSource(
        manga,
        sourceName: 'comick',
        resolver: () => _comicK.findConservativeMatch(manga),
        fetch: _comicK.getChapters,
      );

  Future<List<CanonicalChapter>> _loadWeebCentral(
    Manga manga, {
    required bool allowAdult,
  }) =>
      _loadMappedSource(
        manga,
        sourceName: 'weebcentral',
        resolver: () => _weebCentral.findConservativeMatch(
          manga,
          allowAdult: allowAdult,
        ),
        fetch: _weebCentral.getChapters,
      );

  Future<List<CanonicalChapter>> _loadAsura(Manga manga) => _loadMappedSource(
        manga,
        sourceName: 'asura',
        resolver: () => _asura.findConservativeMatch(manga),
        fetch: _asura.getChapters,
      );


  Future<List<CanonicalChapter>> _loadWebtoonXyz(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'webtoonxyz',
        resolver: () => _webtoonXyz.findConservativeMatch(manga),
        fetch: _webtoonXyz.getChapters,
      );
  Future<List<CanonicalChapter>> _loadMangaPill(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'mangapill',
        resolver: () => _mangaPill.findConservativeMatch(manga),
        fetch: _mangaPill.getChapters,
      );

  Future<List<CanonicalChapter>> _loadMappedSource(
    Manga manga, {
    required String sourceName,
    required Future<String?> Function() resolver,
    required Future<List<CanonicalChapter>> Function(String sourceId) fetch,
  }) async {
    final key = '${manga.id}|$sourceName';
    var sourceId = await _resolveMapped(
      manga,
      sourceName: sourceName,
      resolver: resolver,
    );
    if (sourceId == null) return const [];

    List<CanonicalChapter> values;
    try {
      values = await fetch(sourceId);
      if (values.isNotEmpty) return values;
    } catch (_) {
      // Treat a 404/site migration exactly like an empty stale mapping.
      values = const <CanonicalChapter>[];
    }

    // A persisted fuzzy mapping can become stale after a site migration or a
    // bad match. Never let one empty/failed cached mapping permanently make a
    // manga look chapterless. Re-resolve it once.
    await _clearMapping(key);
    final rematched = await resolver();
    if (rematched == null || rematched.trim().isEmpty || rematched == sourceId) {
      return const [];
    }

    sourceId = rematched;
    _sourceMatchCache[key] = sourceId;
    await _indexCache.writeMapping(key, sourceId);
    try {
      return await fetch(sourceId);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _resolveMapped(
    Manga manga, {
    required String sourceName,
    required Future<String?> Function() resolver,
  }) async {
    final key = '${manga.id}|$sourceName';
    final memory = _sourceMatchCache[key];
    if (memory != null) return memory;

    final stored = await _indexCache.readMapping(key);
    if (stored != null) {
      _sourceMatchCache[key] = stored;
      return stored;
    }

    final result = await resolver();
    if (result != null && result.trim().isNotEmpty) {
      _sourceMatchCache[key] = result;
      await _indexCache.writeMapping(key, result);
    }
    return result;
  }

  Future<void> _clearMapping(String key) async {
    _sourceMatchCache.remove(key);
    await _indexCache.removeMapping(key);
  }

  Future<void> _storeChapterIndex(
    Manga manga,
    String cacheKey,
    List<CanonicalChapter> chapters, {
    required bool markChecked,
    bool markDeepChecked = false,
  }) async {
    await _indexCache.writeChapters(
      cacheKey,
      chapters,
      markChecked: markChecked,
      markDeepChecked: markDeepChecked,
    );
    _rememberChapterIndex(manga, cacheKey, chapters, notify: true);
  }

  void _rememberChapterIndex(
    Manga manga,
    String cacheKey,
    List<CanonicalChapter> chapters, {
    required bool notify,
  }) {
    final previous = _chapterCache[cacheKey];
    _chapterCache[cacheKey] = chapters;

    MangaChapterRegistry.remember(
      manga.id,
      chapters.length,
      latestNumber: _latestNumber(chapters),
    );
    final existing = _cache[manga.id] ?? manga;
    _cache[manga.id] = existing.copyWith(chapterCount: chapters.length);

    if (notify && !_sameIndex(previous, chapters)) {
      _chapterUpdateController.add(manga.id);
    }
  }

  bool _sameIndex(
    List<CanonicalChapter>? left,
    List<CanonicalChapter> right,
  ) {
    if (left == null || left.length != right.length) return false;
    if (left.isEmpty && right.isEmpty) return true;

    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      if (a.id != b.id ||
          a.number != b.number ||
          a.title != b.title ||
          a.publishedAt != b.publishedAt ||
          a.sourceCopies.length != b.sourceCopies.length) {
        return false;
      }
      for (var copy = 0; copy < a.sourceCopies.length; copy++) {
        final x = a.sourceCopies[copy];
        final y = b.sourceCopies[copy];
        if (x.sourceId != y.sourceId ||
            x.chapterId != y.chapterId ||
            x.publishedAt != y.publishedAt ||
            x.externalUrl != y.externalUrl) {
          return false;
        }
      }
    }
    return true;
  }

  double? _latestNumber(List<CanonicalChapter> chapters) {
    double? latest;
    for (final chapter in chapters) {
      final number = chapter.number;
      if (number == null || !number.isFinite || number < 0) continue;
      if (latest == null || number > latest) latest = number;
    }
    return latest;
  }

  String _chapterCacheKey(Manga manga, bool allowAdult) {
    // Preserve good V6 indexes for normal titles. Adult titles intentionally
    // use a fresh V7 key so a bad V6 adult mapping/index cannot keep a title
    // permanently chapterless after the resolver fix.
    if (manga.isAdult && allowAdult) {
      return '${manga.id}|adult:v8';
    }
    return '${manga.id}|adult:false';
  }

  List<CanonicalChapter> _mergeChapters(List<CanonicalChapter> chapters) {
    final merged = <String, CanonicalChapter>{};

    for (final chapter in chapters) {
      final number = chapter.number;
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }

      final normalizedTitle = _normalize(chapter.title);
      final key = number == null
          ? 'special:$normalizedTitle'
          : 'number:${_numberLabel(number)}';
      if (number == null && normalizedTitle.isEmpty) continue;

      final existing = merged[key];
      if (existing == null) {
        final copies = _dedupeCopies(chapter.sourceCopies);
        if (copies.isEmpty) continue;
        merged[key] = CanonicalChapter(
          id: 'chapter:$key',
          number: number,
          title: chapter.title,
          publishedAt: _preferredPublishedDate(copies, chapter.publishedAt),
          sourceCopies: copies,
        );
        continue;
      }

      final copies = _dedupeCopies([
        ...existing.sourceCopies,
        ...chapter.sourceCopies,
      ]);

      merged[key] = CanonicalChapter(
        id: existing.id,
        number: existing.number ?? chapter.number,
        title: _bestTitle(existing.title, chapter.title),
        publishedAt: _preferredPublishedDate(
          copies,
          _latestMeaningful(existing.publishedAt, chapter.publishedAt),
        ),
        sourceCopies: copies,
      );
    }

    final values = merged.values.toList()
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

  List<ChapterSourceCopy> _dedupeCopies(List<ChapterSourceCopy> input) {
    final copies = <String, ChapterSourceCopy>{};
    for (final copy in input) {
      copies['${copy.sourceId}|${copy.chapterId}'] = copy;
    }
    final values = copies.values.toList()
      ..sort((a, b) => b.reliability.compareTo(a.reliability));
    return values;
  }

  DateTime _preferredPublishedDate(
    List<ChapterSourceCopy> copies,
    DateTime fallback,
  ) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    var latest = fallback;

    for (final copy in copies) {
      final value = copy.publishedAt;
      if (value == epoch) continue;
      if (latest == epoch || value.isAfter(latest)) latest = value;
    }

    return latest;
  }

  String _bestTitle(String left, String right) {
    final generic = RegExp(
      r'^(?:chapter|ch\.?)\s*#?\s*\d+(?:\.\d+)?$',
      caseSensitive: false,
    );
    final leftGeneric = generic.hasMatch(left.trim());
    final rightGeneric = generic.hasMatch(right.trim());
    if (leftGeneric && !rightGeneric) return right;
    if (!leftGeneric && rightGeneric) return left;
    return right.length > left.length ? right : left;
  }

  DateTime _latestMeaningful(DateTime left, DateTime right) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (left == epoch) return right;
    if (right == epoch) return left;
    return left.isAfter(right) ? left : right;
  }

  Future<ChapterPages> pages(
    CanonicalChapter chapter, {
    Set<String> skipSourceIds = const <String>{},
  }) async {
    final copies = [...chapter.sourceCopies]
      ..sort((a, b) => b.reliability.compareTo(a.reliability));

    Object? lastError;
    for (final copy in copies) {
      if (!copy.isDirectlyReadable || skipSourceIds.contains(copy.sourceId)) {
        continue;
      }
      try {
        if (copy.sourceId == 'demo') return demoPages(copy.chapterId);
        if (copy.sourceId == _weebCentral.id) {
          return await _weebCentral.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _mangaDex.id) {
          return await _mangaDex.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _comicK.id) {
          return await _comicK.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _asura.id) {
          return await _asura.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _mangaPill.id) {
          return await _mangaPill.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _webtoonXyz.id) {
          return await _webtoonXyz.getChapterPages(copy.chapterId);
        }
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError ?? StateError('Chapter unavailable right now.');
  }

  List<Manga> _dedupe(List<Manga> values) {
    final map = <String, Manga>{};
    for (final manga in values) {
      final key = manga.anilistId?.toString() ?? _normalize(manga.title);
      map.putIfAbsent(key, () => manga);
    }
    return map.values.toList();
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
