import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../identity/manga_identity_resolver.dart';
import '../identity/chapter_identity.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/chapter_index_cache.dart';

import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/demonic_scans_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangakakalot_source.dart';
import '../../features/reader/data/mangakatana_source.dart';
import '../../features/reader/data/weebcentral_source.dart';
import '../../features/search/data/metadata_provider.dart';
import '../../shared/demo_catalog.dart';

class SourceHealthSnapshot {
  const SourceHealthSnapshot({
    required this.sourceId,
    required this.consecutiveFailures,
    required this.lastLatency,
    required this.lastCheckedAt,
    this.lastError,
  });

  final String sourceId;
  final int consecutiveFailures;
  final Duration lastLatency;
  final DateTime lastCheckedAt;
  final String? lastError;

  bool get isDegraded => consecutiveFailures >= 2;
}

class CatalogRepository {
  CatalogRepository({
    required this.config,
    required this.metadata,
    List<MetadataProvider>? metadataProviders,
    required this.mangaDex,
    DemonicScansSource? demonicScans,
    MangakakalotSource? mangakakalot,
    MangaKatanaSource? mangaKatana,
    AsuraSource? asura,
    WeebCentralSource? weebCentral,
    ChapterIndexCache? chapterIndexCache,
  }) : _metadataProviders = List.unmodifiable(
         metadataProviders ?? <MetadataProvider>[metadata],
       ),
       _demonicScans = demonicScans ?? DemonicScansSource(),
       _mangakakalot = mangakakalot ?? MangakakalotSource(),
       _mangaKatana = mangaKatana ?? MangaKatanaSource(),
       _asura = asura ?? AsuraSource(),
       _weebCentral = weebCentral ?? WeebCentralSource(),
       _indexCache = chapterIndexCache ?? ChapterIndexCache() {
    if (config.useDemoData) {
      for (final manga in demoCatalog) {
        _cache[manga.id] = manga;
      }
    }
  }

  final AppConfig config;
  final MetadataProvider metadata;
  final List<MetadataProvider> _metadataProviders;
  final MangaIdentityResolver _identityResolver = const MangaIdentityResolver();
  final MangaDexSource mangaDex;
  final DemonicScansSource _demonicScans;
  final MangakakalotSource _mangakakalot;
  final MangaKatanaSource _mangaKatana;
  final AsuraSource _asura;
  final WeebCentralSource _weebCentral;
  final ChapterIndexCache _indexCache;

  final Map<String, Manga> _cache = {};
  final Map<String, Manga> _bookmarkedCanonicals = {};
  final Map<String, Future<Manga?>> _detailsLoading = {};
  final Map<String, List<CanonicalChapter>> _chapterCache = {};
  final Map<String, String> _sourceMatchCache = {};
  final Map<String, Future<List<CanonicalChapter>>> _refreshing = {};
  final Map<String, Future<List<CanonicalChapter>>> _initialLoading = {};
  final Map<String, Future<List<CanonicalChapter>?>> _localLookups = {};
  final Set<String> _knownMissingIndexes = {};
  final Map<String, Manga> _libraryWarmupQueue = {};
  final Set<String> _libraryWarmupActive = {};
  Future<void>? _libraryWarmup;
  final Map<String, Manga> _summaryWarmupQueue = {};
  final Set<String> _summaryWarmupActive = {};
  final Map<String, DateTime> _summaryWarmupChecked = {};
  Future<void>? _summaryWarmup;
  final StreamController<String> _chapterUpdateController =
      StreamController<String>.broadcast();
  final StreamController<SourceHealthSnapshot> _sourceHealthController =
      StreamController<SourceHealthSnapshot>.broadcast();
  final Map<String, SourceHealthSnapshot> _sourceHealth = {};

  static const _primaryTimeout = Duration(seconds: 14);
  static const _fallbackTimeout = Duration(seconds: 22);
  static const _firstChapterDeadline = Duration(seconds: 6);
  static const _quickRefreshAge = Duration(minutes: 10);
  static const _deepRefreshAge = Duration(hours: 6);
  static const _enabledSourceIds = <String>{
    'demo',
    'mangadex',
    'asura',
    'demonicscans',
    'mangakakalot',
    'mangakatana',
    'weebcentral',
  };

  Stream<String> get chapterUpdates => _chapterUpdateController.stream;
  Stream<SourceHealthSnapshot> get sourceHealthUpdates =>
      _sourceHealthController.stream;
  List<SourceHealthSnapshot> get sourceHealth {
    final values = _sourceHealth.values.toList(growable: false)
      ..sort((left, right) => left.sourceId.compareTo(right.sourceId));
    return values;
  }

  List<Manga> get demoRankings =>
      config.useDemoData ? demoCatalog : const <Manga>[];

  bool isFriendly(Manga manga) => manga.isFriendlyContent;

  /// Rejects stale source-only search records saved before the current
  /// metadata provider set was configured. Canonical records may retain
  /// chapter mappings without being treated as metadata from those sources.
  bool isEnabledMetadataResult(Manga manga) {
    if (manga.id.startsWith('demo:')) return true;
    final metadataIds = manga.allMetadataProviderIds;
    final sourceIds = manga.allSourceMappings;
    if (metadataIds.isEmpty && sourceIds.isEmpty) return true;
    final enabledIds = _metadataProviders
        .map((provider) => provider.id)
        .toSet();
    if (metadataIds.keys.any(enabledIds.contains)) return true;
    return !metadataIds.keys.any(_enabledSourceIds.contains);
  }

  bool isFriendlySearchQuery(String query) => Manga.isFriendlySearchText(query);

  /// Resolves an imported bookmark through its exact reader source before
  /// falling back to title search. This is both faster and more reliable for
  /// source titles whose display name differs from canonical metadata.
  Future<Manga?> resolveImportedSource({
    required String source,
    required String sourceMangaId,
    String? sourceUrl,
  }) async {
    final coordinates = _importSourceCoordinates(
      source,
      sourceMangaId,
      sourceUrl,
    );
    if (coordinates == null) return null;
    final (:sourceId, :mangaId) = coordinates;
    final startedAt = DateTime.now();
    try {
      final Manga? loaded = await switch (sourceId) {
        'mangadex' => mangaDex.getMangaDetails(mangaId),
        'demonicscans' => _demonicScans.getMangaDetails(mangaId),
        'mangakakalot' => _mangakakalot.getMangaDetails(mangaId),
        'mangakatana' => _mangaKatana.getMangaDetails(mangaId),
        'asura' => _asura.getMangaDetails(mangaId),
        'weebcentral' => _weebCentral.getMangaDetails(mangaId),
        _ => Future<Manga?>.value(),
      }.timeout(_primaryTimeout);
      _recordSourceHealth(sourceId, startedAt: startedAt);
      if (loaded == null || !isFriendly(loaded)) return null;
      final hasSafetyEvidence =
          loaded.hasTrustedSafetyMetadata ||
          loaded.synopsis.trim().isNotEmpty ||
          loaded.genres.isNotEmpty;
      if (!hasSafetyEvidence) return null;
      final isMetadataSource = _metadataProviders.any(
        (provider) => provider.id == sourceId,
      );
      final mapped = loaded.copyWith(
        metadataProviderIds: {
          ...loaded.metadataProviderIds,
          if (isMetadataSource) sourceId: mangaId,
        },
        sourceMappings: {...loaded.sourceMappings, sourceId: mangaId},
      );
      remember(mapped);
      return canonicalizeForLibrary(mapped);
    } catch (error) {
      if (!_isCancellation(error)) {
        _recordSourceHealth(sourceId, startedAt: startedAt, error: error);
      }
      return null;
    }
  }

  ({String sourceId, String mangaId})? _importSourceCoordinates(
    String rawSource,
    String rawId,
    String? rawUrl,
  ) {
    final source = rawSource.trim().toLowerCase();
    final uri = Uri.tryParse(rawUrl ?? '');
    final host = uri?.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final sourceId = switch (source) {
      'mangadex' => 'mangadex',
      'demonicscans' => 'demonicscans',
      'mangakakalot' => 'mangakakalot',
      'mangakatana' => 'mangakatana',
      'asura' => 'asura',
      'weebcentral' => 'weebcentral',
      _ when host == 'mangadex.org' => 'mangadex',
      _ when host == 'demonicscans.org' => 'demonicscans',
      _ when host == 'mangakakalot.gg' => 'mangakakalot',
      _ when host == 'mangakatana.com' => 'mangakatana',
      _ when host == 'weebcentral.com' => 'weebcentral',
      _ when host?.contains('asura') == true => 'asura',
      _ => '',
    };
    if (sourceId.isEmpty) return null;

    final path = uri?.path ?? '';
    String? fromUrl;
    switch (sourceId) {
      case 'mangadex':
        fromUrl = RegExp(
          r'/title/([0-9a-f-]{36})',
          caseSensitive: false,
        ).firstMatch(path)?.group(1);
      case 'demonicscans':
        if (RegExp(r'^/manga/[^/?#]+/?$').hasMatch(path)) {
          fromUrl = Uri.encodeComponent(path.replaceFirst(RegExp(r'/$'), ''));
        }
      case 'mangakakalot':
        fromUrl = RegExp(
          r'^/manga/([a-z0-9]+(?:-[a-z0-9]+)*)/?$',
          caseSensitive: false,
        ).firstMatch(path)?.group(1)?.toLowerCase();
      case 'mangakatana':
        fromUrl = RegExp(
          r'^/manga/([^/?#\s]+\.\d+)/?$',
          caseSensitive: false,
        ).firstMatch(path)?.group(1)?.toLowerCase();
      case 'asura':
        final clean = path
            .replaceFirst(RegExp(r'^/'), '')
            .replaceFirst(RegExp(r'/$'), '');
        if (clean.startsWith('comics/')) fromUrl = Uri.encodeComponent(clean);
      case 'weebcentral':
        fromUrl = RegExp(r'^/series/([A-Za-z0-9]+)').firstMatch(path)?.group(1);
    }
    final mangaId = (fromUrl ?? rawId).trim();
    if (mangaId.isEmpty || mangaId.length > 500) return null;
    return (sourceId: sourceId, mangaId: mangaId);
  }

  Manga? cached(String id) {
    final value = _cache[id];
    return value == null || !isFriendly(value) ? null : value;
  }

  /// Keeps imported/native bookmarks as the canonical app identity. Results
  /// arriving later from another metadata provider are enriched with their
  /// IDs, but retain the bookmarked ID used by progress and chapter caches.
  void syncBookmarkedManga(Iterable<Manga> values) {
    _bookmarkedCanonicals
      ..clear()
      ..addEntries(
        values.where(isFriendly).map((manga) => MapEntry(manga.id, manga)),
      );
    for (final manga in _bookmarkedCanonicals.values) {
      _cache[manga.id] = manga;
      _cache[manga.tsukiId] = manga;
    }
  }

  Manga canonicalizeForLibrary(Manga manga) {
    if (!isFriendly(manga)) return manga;
    for (final bookmarked in _bookmarkedCanonicals.values) {
      final comparison = _identityResolver.compare(bookmarked, manga);
      if (!comparison.canMerge) continue;
      final merged = _identityResolver
          .merge(bookmarked, manga)
          .copyWith(id: bookmarked.id);
      _cache[manga.id] = merged;
      _cache[manga.tsukiId] = merged;
      _cache[bookmarked.id] = merged;
      _cache[bookmarked.tsukiId] = merged;
      return merged;
    }
    return manga;
  }

  void remember(Manga manga) {
    if (!isFriendly(manga)) return;
    final resolved = canonicalizeForLibrary(manga);
    _cache[manga.id] = resolved;
    _cache[manga.tsukiId] = resolved;
    _cache[resolved.id] = resolved;
    _cache[resolved.tsukiId] = resolved;
  }

  /// Source-only autocomplete stays broad, but chapters/imports require a
  /// second safety pass over full source details. Canonical providers already
  /// expose explicit adult/rating signals and do not need this extra request.
  Future<Manga?> verifyForOpen(Manga manga) async {
    if (!isFriendly(manga)) return null;
    if (manga.hasTrustedSafetyMetadata || manga.id.startsWith('demo:')) {
      return manga;
    }

    final verificationMappings = <String, String>{
      ...manga.allMetadataProviderIds,
      ...manga.allSourceMappings,
    };
    for (final mapping in verificationMappings.entries) {
      final provider = _metadataProviders
          .where((candidate) => candidate.id == mapping.key)
          .firstOrNull;
      if (provider == null) continue;
      try {
        final details = await provider.getById(
          '${mapping.key}:${mapping.value}',
        );
        if (details == null) continue;
        if (!isFriendly(details)) return null;
        final hasSafetyEvidence =
            details.synopsis.trim().isNotEmpty || details.genres.isNotEmpty;
        if (!hasSafetyEvidence) continue;
        final comparison = _identityResolver.compare(manga, details);
        if (!comparison.canMerge) continue;
        final verified = _identityResolver.merge(manga, details);
        if (!isFriendly(verified)) return null;
        remember(verified);
        return canonicalizeForLibrary(verified);
      } catch (_) {
        // Try another known mapping, then canonical metadata search below.
      }
    }

    // A source page may be temporarily unavailable or too sparse for a safety
    // decision. Resolve the same title through the canonical metadata set
    // before giving up, so normal browsing is not blocked by one scraper.
    final fallbackQueries = <String>{
      manga.title,
      ...manga.aliases,
    }.map((value) => value.trim()).where((value) => value.length >= 2).take(3);
    for (final query in fallbackQueries) {
      try {
        final candidates = await searchMetadataOnly(query);
        for (final candidate in candidates) {
          if (!candidate.hasTrustedSafetyMetadata || !isFriendly(candidate)) {
            continue;
          }
          if (!_identityResolver.compare(manga, candidate).canMerge) continue;
          final verified = _identityResolver.merge(candidate, manga);
          if (!isFriendly(verified)) return null;
          remember(verified);
          return canonicalizeForLibrary(verified);
        }
      } catch (_) {
        // Other spellings and already-loaded results remain available.
      }
    }
    return null;
  }

  Future<List<Manga>> searchMetadataOnly(
    String query, {
    CancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2 || !isFriendlySearchQuery(trimmed)) {
      return const [];
    }

    final batches = await searchMetadataProgressive(
      trimmed,
      cancelToken: cancelToken,
    ).toList();
    final safe = batches.isEmpty ? const <Manga>[] : batches.last;
    for (final value in safe) {
      _cache[value.id] = value;
    }
    return _rankSearchResults(query, safe);
  }

  /// Emits a merged result after each provider completes. Provider failures
  /// and timeouts are isolated, so a slow fallback never blocks useful data.
  Stream<List<Manga>> searchMetadataProgressive(
    String query, {
    CancelToken? cancelToken,
  }) async* {
    final trimmed = query.trim();
    if (trimmed.length < 2 || !isFriendlySearchQuery(trimmed)) return;

    final controller = StreamController<List<Manga>>();
    final merged = <Manga>[];
    var remaining = _metadataProviders.length;

    void completeOne() {
      remaining--;
      if (remaining == 0) unawaited(controller.close());
    }

    for (var index = 0; index < _metadataProviders.length; index++) {
      final provider = _metadataProviders[index];
      final startedAt = DateTime.now();
      unawaited(
        provider
            .search(trimmed, cancelToken: cancelToken)
            .timeout(Duration(seconds: index == 0 ? 8 : 10))
            .then((values) {
              _recordSourceHealth(provider.id, startedAt: startedAt);
              for (final rawCandidate in values.where(isFriendly)) {
                final candidate = canonicalizeForLibrary(rawCandidate);
                final matchIndex = merged.indexWhere(
                  (current) =>
                      _identityResolver.compare(current, candidate).canMerge,
                );
                if (matchIndex < 0) {
                  merged.add(candidate);
                } else {
                  merged[matchIndex] = _identityResolver.merge(
                    merged[matchIndex],
                    candidate,
                  );
                }
              }
              final ranked = _rankSearchResults(trimmed, [...merged]);
              for (final manga in ranked) {
                _cache[manga.id] = manga;
                _cache[manga.tsukiId] = manga;
              }
              if (!controller.isClosed) controller.add(ranked);
            })
            .catchError((error) {
              if (!_isCancellation(error)) {
                _recordSourceHealth(
                  provider.id,
                  startedAt: startedAt,
                  error: error,
                );
              }
            })
            .whenComplete(completeOne),
      );
    }

    yield* controller.stream;
  }

  List<Manga> _rankSearchResults(String query, List<Manga> values) {
    final needle = _searchKey(query);
    if (needle.isEmpty || values.length < 2) return values;

    double score(Manga manga) {
      final names = <String>[
        manga.title,
        ...manga.aliases,
      ].map(_searchKey).where((value) => value.isNotEmpty).toList();
      if (names.isEmpty) return 0;

      var best = 0.0;
      for (final name in names) {
        final value = name == needle
            ? 1000.0
            : name.startsWith(needle)
            ? 760.0 - (name.length - needle.length).clamp(0, 120).toDouble()
            : name.contains(needle)
            ? 520.0 - name.indexOf(needle).clamp(0, 120).toDouble()
            : needle.contains(name)
            ? 260.0
            : 0.0;
        if (value > best) best = value;
      }

      final popularity =
          (manga.popularity ?? 0).clamp(0, 250000).toDouble() / 2500.0;
      final rating = (manga.rating ?? 0) * 4;
      final chapterSignal = manga.metadataChapterCount > 0 ? 8.0 : 0.0;
      return best + popularity + rating + chapterSignal;
    }

    final ranked = [...values];
    ranked.sort((a, b) {
      final byScore = score(b).compareTo(score(a));
      if (byScore != 0) return byScore;

      final byPopularity = (b.popularity ?? 0).compareTo(a.popularity ?? 0);
      if (byPopularity != 0) return byPopularity;

      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return ranked;
  }

  String _searchKey(String value) => value
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<Manga?> details(String id) async {
    final value = _cache[id];
    if (value != null) return isFriendly(value) ? value : null;

    final active = _detailsLoading[id];
    if (active != null) return active;

    final selected = _metadataProviders.where((provider) {
      if (id.contains(':${provider.id}:')) return true;
      return id.startsWith('${provider.id}:');
    }).firstOrNull;
    final provider = selected ?? metadata;
    final future = provider.getById(id).then((loaded) {
      if (loaded == null || !isFriendly(loaded)) return null;
      _cache[id] = loaded;
      return loaded;
    });
    _detailsLoading[id] = future;
    try {
      return await future;
    } finally {
      if (identical(_detailsLoading[id], future)) _detailsLoading.remove(id);
    }
  }

  /// Synchronous memory lookup used by Details/Reader to render a warmed index
  /// without entering a loading state.
  List<CanonicalChapter>? memoryChapters(
    Manga manga, {
    bool allowAdult = false,
  }) {
    if (!isFriendly(manga)) return const <CanonicalChapter>[];
    final value = _chapterCache[_chapterCacheKey(manga, allowAdult)];
    return value == null || value.isEmpty ? null : value;
  }

  /// Starts/finishes a chapter index before navigating to Details. Multiple
  /// cards asking for the same manga share the same in-flight request.
  Future<void> prewarmChapters(Manga manga, {bool allowAdult = false}) async {
    if (config.useDemoData || !isFriendly(manga)) return;
    try {
      await chapters(manga, allowAdult: false);
    } catch (_) {
      // Card rendering must never fail because an optional source is down.
    }
  }

  /// Fast import path: an exported bookmark already identifies its source,
  /// so load that exact index instead of searching every provider first.
  Future<void> prewarmImportedChapters(
    Manga manga, {
    required String preferredSource,
  }) async {
    if (config.useDemoData || !isFriendly(manga)) return;
    final source = preferredSource.trim().toLowerCase();
    if (!_enabledSourceIds.contains(source) || source == 'demo') {
      await prewarmChapters(manga, allowAdult: false);
      return;
    }

    final chapters = await _safe(
      () => _loadSourceByName(manga, source, allowAdult: false),
      timeout: _firstChapterDeadline,
    );
    if (chapters.isEmpty) {
      // Do not hold the import screen for a second provider sweep. Home's
      // bounded queue will retry the uncommon failed/unsupported title.
      queueLibraryWarmup([manga]);
      return;
    }

    await _storeChapterIndex(
      manga,
      _chapterCacheKey(manga, false),
      _mergeChapters(chapters),
      markChecked: true,
    );
  }

  /// Queues a lightweight latest-chapter probe when a card becomes visible.
  ///
  /// This does not download full chapter indexes. It compares the latest
  /// chapter advertised by every matched source and publishes the highest
  /// verified number through [chapterUpdates], allowing cards to update
  /// without requiring a visit to Details.
  void queueChapterSummaryWarmup(Manga manga) {
    if (config.useDemoData || !isFriendly(manga)) return;
    if (manga.status == MangaStatus.notYetReleased ||
        manga.format == MangaFormat.oneShot ||
        (manga.status == MangaStatus.completed && manga.hasChapterMetadata)) {
      return;
    }

    final checked = _summaryWarmupChecked[manga.id];
    if (checked != null &&
        DateTime.now().difference(checked) < _quickRefreshAge) {
      return;
    }
    if (_summaryWarmupActive.contains(manga.id) ||
        _summaryWarmupQueue.containsKey(manga.id)) {
      return;
    }

    _summaryWarmupQueue[manga.id] = manga;
    _summaryWarmup ??= _drainSummaryWarmup();
  }

  Future<void> _drainSummaryWarmup() async {
    try {
      while (_summaryWarmupQueue.isNotEmpty) {
        final batch = _summaryWarmupQueue.values
            .take(3)
            .toList(growable: false);
        for (final manga in batch) {
          _summaryWarmupQueue.remove(manga.id);
          _summaryWarmupActive.add(manga.id);
        }

        await Future.wait(batch.map(_refreshCardChapterSummary));

        final checkedAt = DateTime.now();
        for (final manga in batch) {
          _summaryWarmupActive.remove(manga.id);
          _summaryWarmupChecked[manga.id] = checkedAt;
        }
      }
    } finally {
      _summaryWarmup = null;
      if (_summaryWarmupQueue.isNotEmpty) {
        _summaryWarmup = _drainSummaryWarmup();
      }
    }
  }

  Future<void> _refreshCardChapterSummary(Manga manga) async {
    final probes = await _safeLatestPrimaries(manga, allowAdult: false);
    if (probes.isEmpty) return;

    final freshestProbe = probes.first;
    final probedLatest = freshestProbe.chapter.number;
    if (probedLatest == null) return;
    final metadataTotal = manga.metadataChapterCount.toDouble();
    final candidate = metadataTotal > probedLatest
        ? metadataTotal
        : probedLatest;

    final current = MangaChapterRegistry.summaryFor(manga.id);
    final currentLatest = current?.latestNumber;
    final summaryNeedsUpdate =
        currentLatest == null || currentLatest < candidate;

    // If this title already has a readable on-device index, update that index
    // from the newly discovered freshest source as part of the card refresh.
    // This bypasses an old "recently checked" timestamp that may have been
    // written when only a stale provider was available. Never prefetch entire
    // indexes for never-opened search results.
    final local = await localChapters(manga, allowAdult: false);

    if (summaryNeedsUpdate) {
      final summary = MangaChapterSummary(
        indexCount: current?.indexCount ?? 0,
        latestNumber: candidate,
      );
      await _indexCache.writeSummary(manga.id, summary);

      if (!_chapterUpdateController.isClosed) {
        _chapterUpdateController.add(manga.id);
      }
    }

    if (local == null ||
        local.isEmpty ||
        candidate <= (_latestNumber(local) ?? 0)) {
      return;
    }
    final fresh = await _safe(
      () => _loadSourceByName(manga, freshestProbe.source, allowAdult: false),
    );
    if (fresh.isEmpty) return;

    final merged = _mergeChapters([...local, ...fresh]);
    await _storeChapterIndex(
      manga,
      _chapterCacheKey(manga, false),
      merged,
      markChecked: true,
    );
  }

  /// Queues library chapter discovery with bounded concurrency.
  ///
  /// A manga opens four source requests internally, so warming every bookmark
  /// at once can overwhelm both the device and the remote sources. This queue
  /// processes two manga at a time and coalesces repeated Home rebuilds.
  void queueLibraryWarmup(Iterable<Manga> manga) {
    if (config.useDemoData) return;
    for (final item in manga) {
      final cached = _chapterCache[_chapterCacheKey(item, false)];
      if (!isFriendly(item) ||
          _libraryWarmupActive.contains(item.id) ||
          (cached != null && cached.isNotEmpty)) {
        continue;
      }
      _libraryWarmupQueue[item.id] = item;
    }
    _libraryWarmup ??= _drainLibraryWarmup();
  }

  Future<void> _drainLibraryWarmup() async {
    try {
      while (_libraryWarmupQueue.isNotEmpty) {
        final batch = _libraryWarmupQueue.values
            .take(2)
            .toList(growable: false);
        for (final manga in batch) {
          _libraryWarmupQueue.remove(manga.id);
          _libraryWarmupActive.add(manga.id);
        }
        await Future.wait(batch.map(prewarmChapters));
        for (final manga in batch) {
          _libraryWarmupActive.remove(manga.id);
        }
      }
    } finally {
      _libraryWarmup = null;
      if (_libraryWarmupQueue.isNotEmpty) {
        _libraryWarmup = _drainLibraryWarmup();
      }
    }
  }

  /// Returns only an existing memory/on-device chapter index.
  /// It never performs a source request.
  Future<List<CanonicalChapter>?> localChapters(
    Manga manga, {
    bool allowAdult = false,
  }) async {
    if (!isFriendly(manga)) return const [];
    final cacheKey = _chapterCacheKey(manga, allowAdult);

    final memory = _chapterCache[cacheKey];
    if (memory != null && memory.isNotEmpty) return memory;
    if (_knownMissingIndexes.contains(cacheKey)) return null;

    final active = _localLookups[cacheKey];
    if (active != null) return active;

    final future = _indexCache.readChapters(cacheKey).then((stored) {
      final clean = stored == null ? null : _sanitizeBatch(stored);
      if (clean == null || clean.isEmpty) {
        _knownMissingIndexes.add(cacheKey);
        return null;
      }
      _rememberChapterIndex(manga, cacheKey, clean, notify: false);
      return clean;
    });
    _localLookups[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_localLookups[cacheKey], future)) {
        _localLookups.remove(cacheKey);
      }
    }
  }

  /// Cache-first chapter loading.
  ///
  /// Once a manga has been seen, its local chapter index is returned
  /// immediately. Network refreshes happen after that and publish an update
  /// through [chapterUpdates]. On the first ever open, the sources appropriate
  /// to the active content mode are started once and merged progressively.
  Future<List<CanonicalChapter>> chapters(
    Manga manga, {
    bool refresh = false,
    bool allowAdult = false,
  }) async {
    if (!isFriendly(manga)) return const [];

    if (manga.id.startsWith('demo:')) {
      final values = demoChapters(manga);
      _chapterCache[_chapterCacheKey(manga, allowAdult)] = values;
      return values;
    }

    if (refresh) {
      return refreshChapters(manga, allowAdult: false, force: true);
    }

    final cacheKey = _chapterCacheKey(manga, allowAdult);
    final local = await localChapters(manga, allowAdult: false);
    if (local != null && local.isNotEmpty) {
      _scheduleRefreshIfStale(manga, cacheKey, allowAdult: false);
      return local;
    }

    // First-ever open: start each provider once. The first complete usable
    // source index is returned as soon as it arrives; slower providers keep
    // running and merge their missing chapters into the same cache. This avoids
    // the previous double-fetch (race once, then immediately fetch all again).
    final active = _initialLoading[cacheKey];
    if (active != null) return active;

    final future = _loadInitialProgressively(
      manga,
      cacheKey,
      allowAdult: false,
    );
    _initialLoading[cacheKey] = future;
    // Keep the completed first-result future in this map until every source
    // harvest has finished. That prevents a second navigation/card rebuild
    // from starting the same expensive provider sweep again while slower
    // sources are still merging into the index. _loadInitialProgressively
    // removes it after the final raw source completes.
    return future;
  }

  List<Future<List<CanonicalChapter>> Function()> _loadersFor(
    Manga manga, {
    required bool allowAdult,
  }) {
    if (!isFriendly(manga)) {
      return const <Future<List<CanonicalChapter>> Function()>[];
    }
    return <Future<List<CanonicalChapter>> Function()>[
      () => _trackChapterSource('demonicscans', () => _loadDemonicScans(manga)),
      () => _trackChapterSource('mangakakalot', () => _loadMangakakalot(manga)),
      () => _trackChapterSource('mangakatana', () => _loadMangaKatana(manga)),
      () => _trackChapterSource(
        'mangadex',
        () => _loadMangaDex(manga, allowAdult: false),
      ),
      () => _trackChapterSource('asura', () => _loadAsura(manga)),
      () => _trackChapterSource('weebcentral', () => _loadWeebCentral(manga)),
    ];
  }

  Future<List<CanonicalChapter>> _trackChapterSource(
    String sourceId,
    Future<List<CanonicalChapter>> Function() operation,
  ) async {
    final startedAt = DateTime.now();
    try {
      final values = await operation();
      _recordSourceHealth(sourceId, startedAt: startedAt);
      return values;
    } catch (error) {
      if (!_isCancellation(error)) {
        _recordSourceHealth(sourceId, startedAt: startedAt, error: error);
      }
      rethrow;
    }
  }

  bool _isCancellation(Object error) =>
      error is DioException && CancelToken.isCancel(error);

  void _recordSourceHealth(
    String sourceId, {
    required DateTime startedAt,
    Object? error,
  }) {
    final previous = _sourceHealth[sourceId];
    final snapshot = SourceHealthSnapshot(
      sourceId: sourceId,
      consecutiveFailures: error == null
          ? 0
          : (previous?.consecutiveFailures ?? 0) + 1,
      lastLatency: DateTime.now().difference(startedAt),
      lastCheckedAt: DateTime.now(),
      lastError: error?.toString(),
    );
    _sourceHealth[sourceId] = snapshot;
    if (!_sourceHealthController.isClosed) {
      _sourceHealthController.add(snapshot);
    }
  }

  Future<List<CanonicalChapter>> _loadInitialProgressively(
    Manga manga,
    String cacheKey, {
    required bool allowAdult,
  }) {
    final loaders = _loadersFor(manga, allowAdult: false);
    if (loaders.isEmpty) return Future.value(const <CanonicalChapter>[]);

    final first = Completer<List<CanonicalChapter>>();
    var firstWaitersRemaining = loaders.length;
    var rawRemaining = loaders.length;
    var aggregate = <CanonicalChapter>[];
    var persistChain = Future<void>.value();

    // Never leave Details on an indefinite 'finding chapters' state. The
    // provider harvests keep running in the background, but the UI receives
    // the best result collected so far after this deadline. A late source can
    // still publish a fuller index through chapterUpdates.
    final firstDeadline = Timer(_firstChapterDeadline, () {
      if (!first.isCompleted) first.complete(aggregate);
    });
    unawaited(first.future.then<void>((_) => firstDeadline.cancel()));

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
      // The full progressive harvest is finished. A later explicit retry may
      // now start a fresh sweep if the index remained empty.
      _initialLoading.remove(cacheKey);
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
        raw
            .timeout(
              _fallbackTimeout,
              onTimeout: () => const <CanonicalChapter>[],
            )
            .then((value) {
              final clean = _sanitizeBatch(value);
              if (clean.isNotEmpty && !first.isCompleted) {
                first.complete(_mergeChapters(clean));
              }
              firstWaitersRemaining--;
              if (firstWaitersRemaining == 0 && !first.isCompleted) {
                first.complete(aggregate);
              }
            })
            .catchError((_) {
              firstWaitersRemaining--;
              if (firstWaitersRemaining == 0 && !first.isCompleted) {
                first.complete(aggregate);
              }
            }),
      );
    }

    return first.future;
  }

  Future<List<CanonicalChapter>> refreshChapters(
    Manga manga, {
    bool allowAdult = false,
    bool force = false,
  }) async {
    if (!isFriendly(manga)) return const [];

    final cacheKey = _chapterCacheKey(manga, allowAdult);
    final active = _refreshing[cacheKey];
    if (active != null) return active;

    final future = _refreshChaptersInternal(
      manga,
      cacheKey,
      allowAdult: false,
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
        await localChapters(manga, allowAdult: false) ??
        const <CanonicalChapter>[];

    if (!force &&
        existing.isNotEmpty &&
        !await _indexCache.isStale(cacheKey, _quickRefreshAge)) {
      return existing;
    }

    final deep =
        force ||
        existing.isEmpty ||
        await _indexCache.isStale(cacheKey, _deepRefreshAge, deep: true);

    // Normal refresh probes every enabled source before choosing the newest
    // readable index.
    if (!deep && existing.isNotEmpty) {
      final probes = await _safeLatestPrimaries(manga, allowAdult: false);
      var result = existing;

      // Probe every source before choosing. The old first-response-wins race
      // allowed a fast but stale provider to hide another provider that was
      // tens of chapters newer. Work from newest to oldest and keep trying if
      // a source advertises a new chapter but its readable index then fails.
      for (final probe in probes) {
        if (!_isNewerThanIndex(probe.chapter, result)) continue;
        final fresh = await _safe(
          () => _loadSourceByName(manga, probe.source, allowAdult: false),
        );
        if (fresh.isNotEmpty) {
          result = _mergeChapters([...result, ...fresh]);
        }
      }

      await _storeChapterIndex(manga, cacheKey, result, markChecked: true);
      return result;
    }

    // Deep refresh merges the complete indexes from every enabled source.
    final loaders = _loadersFor(manga, allowAdult: false);

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
        await refreshChapters(manga, allowAdult: false);
      } catch (_) {
        // A working local index must survive temporary source failures.
      }
    }());
  }

  Future<List<({String source, CanonicalChapter chapter})>>
  _safeLatestPrimaries(Manga manga, {required bool allowAdult}) async {
    const sourceOrder = <String>[
      'demonicscans',
      'mangakakalot',
      'mangakatana',
      'mangadex',
      'asura',
      'weebcentral',
    ];

    final probes = await Future.wait(
      sourceOrder.map((source) async {
        try {
          final chapter = await _latestFromSource(
            manga,
            source,
            allowAdult: false,
          ).timeout(_primaryTimeout);
          final number = chapter?.number;
          if (chapter == null ||
              (number != null &&
                  (!number.isFinite || number < 0 || number > 20000))) {
            return null;
          }
          return (source: source, chapter: chapter);
        } catch (_) {
          return null;
        }
      }),
    );

    final available = probes
        .whereType<({String source, CanonicalChapter chapter})>()
        .toList(growable: false);
    available.sort(
      (left, right) => _compareLatestChapters(right.chapter, left.chapter),
    );
    return available;
  }

  int _compareLatestChapters(CanonicalChapter left, CanonicalChapter right) {
    final leftNumber = left.number;
    final rightNumber = right.number;
    if (leftNumber != null && rightNumber != null) {
      final byNumber = leftNumber.compareTo(rightNumber);
      if (byNumber != 0) return byNumber;
    } else if (leftNumber != null) {
      return 1;
    } else if (rightNumber != null) {
      return -1;
    }
    return left.publishedAt.compareTo(right.publishedAt);
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
              resolver: () =>
                  mangaDex.findConservativeMatch(manga, allowAdult: false),
            );
      if (sourceId == null) return null;
      return await mangaDex.getLatestChapter(sourceId);
    }

    if (sourceName == 'demonicscans') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'demonicscans',
        resolver: () => _demonicScans.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _demonicScans.getLatestChapter(sourceId);
    }

    if (sourceName == 'mangakakalot') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'mangakakalot',
        resolver: () => _mangakakalot.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _mangakakalot.getLatestChapter(sourceId);
    }

    if (sourceName == 'mangakatana') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'mangakatana',
        resolver: () => _mangaKatana.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _mangaKatana.getLatestChapter(sourceId);
    }

    if (sourceName == 'asura') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'asura',
        resolver: () => _asura.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _asura.getLatestChapter(sourceId);
    }

    if (sourceName == 'weebcentral') {
      final sourceId = await _resolveMapped(
        manga,
        sourceName: 'weebcentral',
        resolver: () => _weebCentral.findConservativeMatch(manga),
      );
      if (sourceId == null) return null;
      return await _weebCentral.getLatestChapter(sourceId);
    }
    return null;
  }

  Future<List<CanonicalChapter>> _loadSourceByName(
    Manga manga,
    String sourceName, {
    required bool allowAdult,
  }) {
    if (!isFriendly(manga)) return Future.value(const <CanonicalChapter>[]);
    return switch (sourceName) {
      'demonicscans' => _loadDemonicScans(manga),
      'mangakakalot' => _loadMangakakalot(manga),
      'mangakatana' => _loadMangaKatana(manga),
      'mangadex' => _loadMangaDex(manga, allowAdult: false),
      'asura' => _loadAsura(manga),
      'weebcentral' => _loadWeebCentral(manga),
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
      final values = timeout == null
          ? await future
          : await future.timeout(timeout);
      return _sanitizeBatch(values);
    } catch (_) {
      return const [];
    }
  }

  List<CanonicalChapter> _sanitizeBatch(List<CanonicalChapter> values) {
    final result = <CanonicalChapter>[];
    for (final chapter in values) {
      final number = chapter.number;
      final copies = chapter.sourceCopies
          .where((copy) => _enabledSourceIds.contains(copy.sourceId))
          .toList(growable: false);
      if (copies.isEmpty || !copies.any((copy) => copy.isDirectlyReadable)) {
        continue;
      }
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }
      result.add(
        CanonicalChapter(
          id: chapter.id,
          number: chapter.number,
          title: chapter.title,
          publishedAt: chapter.publishedAt,
          sourceCopies: copies,
        ),
      );
    }
    return result;
  }

  Future<List<CanonicalChapter>> _loadMangaDex(
    Manga manga, {
    required bool allowAdult,
  }) async {
    final key = _mappingKey(manga, 'mangadex');
    final directId = manga.allSourceMappings['mangadex'];

    if (directId != null && directId.isNotEmpty) {
      try {
        final directValues = await mangaDex.getChapters(directId);
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
      resolver: () => mangaDex.findConservativeMatch(manga, allowAdult: false),
    );
    if (sourceId == null) return const [];

    try {
      final values = await mangaDex.getChapters(sourceId);
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

  Future<List<CanonicalChapter>> _loadDemonicScans(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'demonicscans',
        resolver: () => _demonicScans.findConservativeMatch(manga),
        fetch: _demonicScans.getChapters,
      );

  Future<List<CanonicalChapter>> _loadMangakakalot(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'mangakakalot',
        resolver: () => _mangakakalot.findConservativeMatch(manga),
        fetch: _mangakakalot.getChapters,
      );

  Future<List<CanonicalChapter>> _loadMangaKatana(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'mangakatana',
        resolver: () => _mangaKatana.findConservativeMatch(manga),
        fetch: _mangaKatana.getChapters,
      );

  Future<List<CanonicalChapter>> _loadAsura(Manga manga) => _loadMappedSource(
    manga,
    sourceName: 'asura',
    resolver: () => _asura.findConservativeMatch(manga),
    fetch: _asura.getChapters,
  );

  Future<List<CanonicalChapter>> _loadWeebCentral(Manga manga) =>
      _loadMappedSource(
        manga,
        sourceName: 'weebcentral',
        resolver: () => _weebCentral.findConservativeMatch(manga),
        fetch: _weebCentral.getChapters,
      );

  Future<List<CanonicalChapter>> _loadMappedSource(
    Manga manga, {
    required String sourceName,
    required Future<String?> Function() resolver,
    required Future<List<CanonicalChapter>> Function(String sourceId) fetch,
  }) async {
    final key = _mappingKey(manga, sourceName);
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
    if (rematched == null ||
        rematched.trim().isEmpty ||
        rematched == sourceId) {
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
    final key = _mappingKey(manga, sourceName);
    final memory = _sourceMatchCache[key];
    if (memory != null) return memory;

    final direct = manga.allSourceMappings[sourceName]?.trim();
    if (direct != null && direct.isNotEmpty) {
      _sourceMatchCache[key] = direct;
      await _indexCache.writeMapping(key, direct);
      return direct;
    }

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
    _knownMissingIndexes.remove(cacheKey);

    MangaChapterRegistry.remember(
      manga.id,
      chapters.length,
      latestNumber: _latestNumber(chapters),
    );
    // Keep AniList's metadata count intact. The verified live chapter summary
    // lives in MangaChapterRegistry/ChapterIndexCache and must not overwrite
    // the metadata fallback used before a source probe completes.
    _cache[manga.id] = _cache[manga.id] ?? manga;

    if (notify &&
        !_chapterUpdateController.isClosed &&
        !_sameIndex(previous, chapters)) {
      _chapterUpdateController.add(manga.id);
    }
  }

  bool _sameIndex(List<CanonicalChapter>? left, List<CanonicalChapter> right) {
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

  String _mappingKey(Manga manga, String sourceName) =>
      '${manga.id}|$sourceName';

  String _chapterCacheKey(Manga manga, bool allowAdult) => '${manga.id}|safe';

  List<CanonicalChapter> _mergeChapters(List<CanonicalChapter> chapters) {
    final merged = <String, CanonicalChapter>{};

    for (final chapter in chapters) {
      final number = chapter.number;
      if (number != null &&
          (!number.isFinite || number < 0 || number > 20000)) {
        continue;
      }

      final key = ChapterIdentity.canonicalKey(number, chapter.title);
      if (key == null) continue;

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
    String? preferredSourceId,
  }) async {
    final copies = [...chapter.sourceCopies]
      ..sort((a, b) {
        final aPreferred = a.sourceId == preferredSourceId;
        final bPreferred = b.sourceId == preferredSourceId;
        if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
        return b.reliability.compareTo(a.reliability);
      });

    Object? lastError;
    for (final copy in copies) {
      if (!copy.isDirectlyReadable || skipSourceIds.contains(copy.sourceId)) {
        continue;
      }
      try {
        if (copy.sourceId == 'demo') return demoPages(copy.chapterId);
        if (copy.sourceId == mangaDex.id) {
          return await mangaDex.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _demonicScans.id) {
          return await _demonicScans.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _mangakakalot.id) {
          return await _mangakakalot.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _mangaKatana.id) {
          return await _mangaKatana.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _asura.id) {
          return await _asura.getChapterPages(copy.chapterId);
        }
        if (copy.sourceId == _weebCentral.id) {
          return await _weebCentral.getChapterPages(copy.chapterId);
        }
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError ?? StateError('Chapter unavailable right now.');
  }

  void dispose() {
    unawaited(_chapterUpdateController.close());
    unawaited(_sourceHealthController.close());
  }
}
