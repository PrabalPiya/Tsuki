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
       _client = client ?? createHttpClient();

  final Future<SharedPreferences> _preferences;
  final String _remoteCatalogUrl;
  final Dio _client;
  List<Manga>? _indexMemory;
  Future<void>? _bundledImport;
  Future<void>? _remoteRefresh;

  static const _rankingPrefix = 'metadata.rankings.';
  static const _searchPrefix = 'metadata.search.';
  static const _indexKey = 'metadata.global_index';
  static const _bundledVersionKey = 'metadata.bundled_catalog_version';
  static const _remoteUpdatedAtKey = 'metadata.remote_catalog_updated_at';
  static const _remoteVersionKey = 'metadata.remote_catalog_version';
  static const _bundledCatalogAsset = 'assets/catalog/catalog.json';
  static const _maxIndexedManga = 2500;
  static const _remoteRefreshInterval = Duration(minutes: 15);

  Future<void> importBundledCatalog() {
    return _bundledImport ??= _importBundledCatalog();
  }

  Future<void> _importBundledCatalog() async {
    try {
      final raw = await rootBundle.loadString(_bundledCatalogAsset);
      final decoded = jsonDecode(raw);
      final payload = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{'items': decoded};
      final version = (payload['version'] as num?)?.toInt() ?? 1;

      final prefs = await _preferences;
      final hasCurrentCatalog = prefs.getInt(_bundledVersionKey) == version;
      if (hasCurrentCatalog && prefs.getString(_indexKey) != null) return;

      final items = _decodeMangaList(payload['items'])
          .where((manga) => manga.hasChapterMetadata)
          .toList(growable: false);
      if (items.isNotEmpty) {
        await mergeManga(items);
      }
      await prefs.setInt(_bundledVersionKey, version);
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
    final payload = await _readPayload('$_searchPrefix${_searchKey(query)}');
    if (payload == null) return null;

    try {
      return _decodeMangaList(payload['items']);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSearch(String query, List<Manga> items) async {
    await _writePayload('$_searchPrefix${_searchKey(query)}', {
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'items': _encodeMangaList(items.take(24).toList(growable: false)),
    });
    await mergeManga(items);
  }

  Future<List<Manga>> searchIndex(String query, {int limit = 24}) async {
    final needle = _indexKeyForText(query);
    if (needle.length < 2) return const <Manga>[];

    await importBundledCatalog();
    final index = await loadIndex();
    final scored = <({Manga manga, double score})>[];

    for (final manga in index) {
      final score = _score(manga, needle);
      if (score > 0) scored.add((manga: manga, score: score));
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

    return scored
        .take(limit)
        .map((entry) => entry.manga)
        .toList(growable: false);
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
      return const <Manga>[];
    }
  }

  Future<List<Manga>> loadCatalogPreview({int limit = 18}) async {
    await importBundledCatalog();
    unawaited(refreshRemoteCatalog());
    return (await loadIndex())
        .where((manga) => manga.hasVerifiedChapterSummary || manga.hasChapterMetadata)
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

  static List<Object?> _encodeMangaList(List<Manga> items) =>
      items.where((manga) => manga.isFriendlyContent).map((manga) {
        return manga.toJson();
      }).toList(growable: false);

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

  static double _score(Manga manga, String needle) {
    final names = <String>[manga.title, ...manga.aliases]
        .map(_indexKeyForText)
        .where((value) => value.isNotEmpty);

    var best = 0.0;
    for (final name in names) {
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

    final genreHit = manga.genres.any((genre) {
      return _indexKeyForText(genre).contains(needle);
    });

    if (best <= 0 && !genreHit) return 0.0;

    final popularity = (manga.popularity ?? 0).clamp(0, 300000) / 6000.0;
    final rating = (manga.rating ?? 0) * 2.0;
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
}
