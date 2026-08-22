import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/discover/data/ranking_provider.dart';
import '../network/http_client.dart';
import '../models/manga.dart';

class MangaMetadataCache {
  MangaMetadataCache({
    Future<SharedPreferences>? preferences,
    String remoteCatalogUrl = '',
    Dio? client,
  }) : _preferences = preferences ?? SharedPreferences.getInstance(),
       _remoteCatalogUrl = remoteCatalogUrl.trim(),
       _client = client ?? createHttpClient(),
       _ownsClient = client == null;

  final Future<SharedPreferences> _preferences;
  final String _remoteCatalogUrl;
  final Dio _client;
  final bool _ownsClient;
  List<Manga>? _indexMemory;
  List<_SearchIndexEntry>? _bundledSearchMemory;
  ({int version, List<Manga> items})? _bundledCatalogMemory;
  Future<void>? _bundledImport;
  Future<({int version, List<Manga> items})>? _bundledCatalogLoad;
  Future<List<_SearchIndexEntry>>? _bundledSearchLoad;
  Future<void>? _remoteRefresh;
  final Map<String, List<Manga>> _searchResultMemory = {};

  static const _rankingPrefix = 'metadata.rankings.';
  static const _searchPrefix = 'metadata.search.';
  static const _searchKeysKey = 'metadata.search_keys';
  static const _indexKey = 'metadata.global_index';
  static const _bundledVersionKey = 'metadata.bundled_catalog_version';
  static const _remoteUpdatedAtKey = 'metadata.remote_catalog_updated_at';
  static const _remoteVersionKey = 'metadata.remote_catalog_version';
  static const _bundledCatalogAsset = 'assets/catalog/catalog.json';
  static const _maxIndexedManga = 2500;
  static const _maxMemoizedSearches = 32;
  static const _maxStoredSearches = 24;
  static const _remoteRefreshInterval = Duration(minutes: 15);

  Future<void> importBundledCatalog() {
    return _bundledImport ??= _importBundledCatalog();
  }

  Future<void> warmSearchIndex() async {
    await _loadBundledSearchIndex();
  }

  Future<void> _importBundledCatalog() async {
    try {
      final bundled = await _loadBundledCatalog();

      final prefs = await _preferences;
      final hasCurrentCatalog =
          prefs.getInt(_bundledVersionKey) == bundled.version;
      if (hasCurrentCatalog && prefs.getString(_indexKey) != null) return;

      final items = bundled.items
          .where((manga) => manga.hasChapterMetadata)
          .toList(growable: false);
      if (items.isNotEmpty) {
        await mergeManga(items);
      }
      await prefs.setInt(_bundledVersionKey, bundled.version);
    } catch (_) {
      // A missing or malformed optional seed catalog must never block startup.
    }
  }

  Future<void> refreshRemoteCatalog({bool force = false}) {
    if (_remoteCatalogUrl.isEmpty) return Future<void>.value();
    if (force) return _refreshRemoteCatalog(force: true);
    return _remoteRefresh ??= _refreshRemoteCatalog();
  }

  Future<void> _refreshRemoteCatalog({bool force = false}) async {
    try {
      final prefs = await _preferences;
      final updatedAt = prefs.getInt(_remoteUpdatedAtKey) ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - updatedAt;
      if (!force && age < _remoteRefreshInterval.inMilliseconds) return;

      final response = await _client.get<Object?>(_remoteCatalogUrl);
      final payload = _payloadFrom(response.data);
      final version = (payload['version'] as num?)?.toInt();

      if (version != null && prefs.getInt(_remoteVersionKey) == version) {
        await prefs.setInt(
          _remoteUpdatedAtKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return;
      }

      final items = _decodeMangaList(payload['items'])
          .where((manga) => manga.hasChapterMetadata)
          .toList(growable: false);
      if (items.isEmpty) return;

      await mergeManga(items);
      if (version != null) await prefs.setInt(_remoteVersionKey, version);
      await prefs.setInt(
        _remoteUpdatedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Remote catalogue refresh is opportunistic; stale local data is fine.
    } finally {
      if (!force) _remoteRefresh = null;
    }
  }

  Future<RankingResult?> loadRanking(RankingPeriod period) async {
    final payload = await _readPayload('$_rankingPrefix${period.name}');
    if (payload == null) return null;

    try {
      return RankingResult(
        items: _decodeMangaList(payload['items']),
        unavailableReason: payload['unavailableReason'] as String?,
        isPreview: payload['isPreview'] as bool? ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveRanking(RankingPeriod period, RankingResult result) async {
    await _writePayload('$_rankingPrefix${period.name}', {
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'unavailableReason': result.unavailableReason,
      'isPreview': result.isPreview,
      'items': _encodeMangaList(result.items),
    });
    await mergeManga(result.items);
  }

  Future<List<Manga>?> loadSearch(String query) async {
    final key = '$_searchPrefix${_searchKey(query)}';
    final payload = await _readPayload(key);
    if (payload == null) return null;

    try {
      return _decodeMangaList(payload['items']);
    } catch (_) {
      await (await _preferences).remove(key);
      return null;
    }
  }

  Future<void> saveSearch(String query, List<Manga> items) async {
    final searchKey = _searchKey(query);
    await _writePayload('$_searchPrefix$searchKey', {
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'items': _encodeMangaList(items.take(50).toList(growable: false)),
    });
    await _pruneStoredSearches(searchKey);

    final current = await _loadBundledSearchIndex();
    final searchableById = <String, Manga>{};
    for (final manga in items.where((manga) => manga.isFriendlyContent)) {
      searchableById[manga.id] = manga;
    }
    for (final entry in current) {
      searchableById.putIfAbsent(entry.manga.id, () => entry.manga);
    }
    final searchable = searchableById.values
        .take(_maxIndexedManga)
        .toList(growable: false);
    _bundledSearchMemory = searchable
        .map(_SearchIndexEntry.new)
        .toList(growable: false);
    _searchResultMemory.clear();
  }

  Future<List<Manga>> searchIndex(String query, {int limit = 24}) async {
    final needle = _indexKeyForText(query);
    if (needle.isEmpty) return const <Manga>[];
    final memoryKey = '$limit:$needle';
    final memoized = _searchResultMemory.remove(memoryKey);
    if (memoized != null) {
      _searchResultMemory[memoryKey] = memoized;
      return memoized;
    }

    final index = await _loadBundledSearchIndex();
    final scored = <({Manga manga, double score})>[];

    for (final entry in index) {
      final score = _scoreEntry(entry, needle);
      if (score > 0) scored.add((manga: entry.manga, score: score));
    }

    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byPopularity = (b.manga.popularity ?? 0).compareTo(
        a.manga.popularity ?? 0,
      );
      if (byPopularity != 0) return byPopularity;
      return a.manga.title.toLowerCase().compareTo(b.manga.title.toLowerCase());
    });

    final result = scored
        .take(limit)
        .map((entry) => entry.manga)
        .toList(growable: false);
    _searchResultMemory[memoryKey] = result;
    if (_searchResultMemory.length > _maxMemoizedSearches) {
      _searchResultMemory.remove(_searchResultMemory.keys.first);
    }
    return result;
  }

  Future<void> _pruneStoredSearches(String newestKey) async {
    final prefs = await _preferences;
    final previous = prefs.getStringList(_searchKeysKey) ?? const <String>[];
    final retained = <String>[
      newestKey,
      ...previous.where((key) => key != newestKey),
    ].take(_maxStoredSearches).toList(growable: false);
    final retainedSet = retained.toSet();
    final stale = prefs
        .getKeys()
        .where((key) => key.startsWith(_searchPrefix))
        .where(
          (key) => !retainedSet.contains(key.substring(_searchPrefix.length)),
        )
        .toList(growable: false);
    await Future.wait(stale.map(prefs.remove));
    await prefs.setStringList(_searchKeysKey, retained);
  }

  Future<List<_SearchIndexEntry>> _loadBundledSearchIndex() {
    final memory = _bundledSearchMemory;
    if (memory != null) return Future.value(memory);
    return _bundledSearchLoad ??= _loadBundledSearchIndexInternal();
  }

  Future<List<_SearchIndexEntry>> _loadBundledSearchIndexInternal() async {
    try {
      final bundled = (await _loadBundledCatalog()).items;
      final stored = await loadIndex();
      final values = <String, Manga>{
        for (final manga in bundled) manga.id: manga,
        for (final manga in stored) manga.id: manga,
      }.values;
      final entries = values
          .where((manga) => manga.isFriendlyContent)
          .map(_SearchIndexEntry.new)
          .toList(growable: false);
      _bundledSearchMemory = entries;
      return entries;
    } catch (_) {
      final stored = await loadIndex();
      final entries = stored.map(_SearchIndexEntry.new).toList(growable: false);
      _bundledSearchMemory = entries;
      return entries;
    } finally {
      _bundledSearchLoad = null;
    }
  }

  Future<({int version, List<Manga> items})> _loadBundledCatalog() {
    final memory = _bundledCatalogMemory;
    if (memory != null) return Future.value(memory);
    return _bundledCatalogLoad ??= _loadBundledCatalogInternal();
  }

  Future<({int version, List<Manga> items})>
  _loadBundledCatalogInternal() async {
    try {
      final raw = await rootBundle.loadString(_bundledCatalogAsset);
      final decoded = jsonDecode(raw);
      final payload = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{'items': decoded};
      final value = (
        version: (payload['version'] as num?)?.toInt() ?? 1,
        items: _decodeMangaList(payload['items']),
      );
      _bundledCatalogMemory = value;
      return value;
    } finally {
      _bundledCatalogLoad = null;
    }
  }

  Future<List<Manga>> loadIndex() async {
    final memory = _indexMemory;
    if (memory != null) return memory;

    final payload = await _readPayload(_indexKey);
    if (payload == null) return const <Manga>[];

    try {
      final values = _decodeMangaList(payload['items']);
      _indexMemory = values;
      return values;
    } catch (_) {
      await (await _preferences).remove(_indexKey);
      return const <Manga>[];
    }
  }

  Future<List<Manga>> loadCatalogPreview({int limit = 18}) async {
    await importBundledCatalog();
    unawaited(refreshRemoteCatalog());
    return (await loadIndex())
        .where(
          (manga) =>
              manga.hasVerifiedChapterSummary || manga.hasChapterMetadata,
        )
        .take(limit)
        .toList(growable: false);
  }

  Future<void> mergeManga(List<Manga> items) async {
    final safe = items.where(
      (manga) =>
          manga.isFriendlyContent &&
          (manga.hasVerifiedChapterSummary || manga.hasChapterMetadata),
    );
    if (safe.isEmpty) return;

    final existing = {for (final manga in await loadIndex()) manga.id: manga};

    for (final manga in safe) {
      existing[manga.id] = manga;
    }

    final values = existing.values.toList(growable: false)
      ..sort((a, b) {
        final byPopularity = (b.popularity ?? 0).compareTo(a.popularity ?? 0);
        if (byPopularity != 0) return byPopularity;
        final byRating = (b.rating ?? 0).compareTo(a.rating ?? 0);
        if (byRating != 0) return byRating;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

    final limited = values.take(_maxIndexedManga).toList(growable: false);
    _indexMemory = limited;
    _searchResultMemory.clear();

    final searchMemory = _bundledSearchMemory;
    if (searchMemory != null) {
      final searchable = <String, Manga>{
        for (final entry in searchMemory) entry.manga.id: entry.manga,
        for (final manga in limited) manga.id: manga,
      };
      _bundledSearchMemory = searchable.values
          .map(_SearchIndexEntry.new)
          .toList(growable: false);
    }

    await _writePayload(_indexKey, {
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'items': _encodeMangaList(limited),
    });
  }

  Future<Map<String, dynamic>?> _readPayload(String key) async {
    final prefs = await _preferences;
    final raw = prefs.getString(key);
    if (raw == null) return null;

    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
  }

  Future<void> _writePayload(String key, Map<String, Object?> payload) async {
    final prefs = await _preferences;
    await prefs.setString(key, jsonEncode(payload));
  }

  static List<Object?> _encodeMangaList(List<Manga> items) => items
      .where((manga) => manga.isFriendlyContent)
      .map((manga) {
        return manga.toJson();
      })
      .toList(growable: false);

  static List<Manga> _decodeMangaList(Object? raw) {
    final values = raw as List? ?? const [];
    return values
        .map((value) => Manga.fromJson(Map<String, dynamic>.from(value as Map)))
        .where((manga) => manga.isFriendlyContent)
        .toList(growable: false);
  }

  static Map<String, dynamic> _payloadFrom(Object? raw) {
    final decoded = raw is String ? jsonDecode(raw) : raw;
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : <String, dynamic>{'items': decoded};
  }

  static String _searchKey(String query) {
    final normalized = query.trim().toLowerCase();
    return base64Url.encode(utf8.encode(normalized));
  }

  static double _scoreEntry(_SearchIndexEntry entry, String needle) {
    var best = 0.0;
    for (final name in entry.names) {
      final value = name == needle
          ? 1000.0
          : name.startsWith(needle)
          ? 850.0 - (name.length - needle.length).clamp(0, 150).toDouble()
          : name.contains(needle)
          ? 560.0 - name.indexOf(needle).clamp(0, 160).toDouble()
          : needle.contains(name) && name.length >= 3
          ? 240.0
          : 0.0;
      if (value > best) best = value;
    }

    final compactNeedle = _compactSearchKey(needle);
    if (compactNeedle.length >= 2) {
      for (final name in entry.compactNames) {
        final value = name == compactNeedle
            ? 940.0
            : name.startsWith(compactNeedle)
            ? 780.0 -
                  (name.length - compactNeedle.length).clamp(0, 140).toDouble()
            : name.contains(compactNeedle)
            ? 500.0 - name.indexOf(compactNeedle).clamp(0, 140).toDouble()
            : 0.0;
        if (value > best) best = value;
      }
    }

    final genreHit = entry.genres.any((genre) => genre.contains(needle));

    if (best <= 0 && !genreHit) return 0.0;

    final popularity = (entry.manga.popularity ?? 0).clamp(0, 300000) / 6000.0;
    final rating = (entry.manga.rating ?? 0) * 2.0;
    return best + (genreHit ? 120.0 : 0.0) + popularity + rating;
  }

  static String _indexKeyForText(String value) {
    return value
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _compactSearchKey(String value) {
    return value.replaceAll(' ', '');
  }

  void dispose() {
    if (_ownsClient) _client.close(force: true);
  }
}

class _SearchIndexEntry {
  _SearchIndexEntry(this.manga)
    : names = <String>{manga.title, ...manga.aliases}
          .map(MangaMetadataCache._indexKeyForText)
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      compactNames = <String>{manga.title, ...manga.aliases}
          .map(MangaMetadataCache._indexKeyForText)
          .map(MangaMetadataCache._compactSearchKey)
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      genres = manga.genres
          .map(MangaMetadataCache._indexKeyForText)
          .where((value) => value.isNotEmpty)
          .toList(growable: false);

  final Manga manga;
  final List<String> names;
  final List<String> compactNames;
  final List<String> genres;
}
