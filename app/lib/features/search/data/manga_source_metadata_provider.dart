import 'package:dio/dio.dart';

import '../../../core/models/manga.dart';
import '../../reader/data/manga_source.dart';
import 'metadata_provider.dart';

/// Exposes a chapter source's catalogue through the metadata search pipeline.
///
/// Every result is tagged with the same stable source mapping used to load its
/// chapters. The shared identity resolver can therefore merge equivalent
/// results without losing any of their directly-readable sources.
class MangaSourceMetadataProvider implements MetadataProvider {
  MangaSourceMetadataProvider(this.source);

  final MangaSource source;
  final Map<String, Manga> _cache = <String, Manga>{};
  final Map<String, ({DateTime savedAt, List<Manga> values})> _searchCache = {};
  final Map<String, ({Future<List<Manga>> future, CancelToken? cancelToken})>
  _searching = {};

  static const _searchTtl = Duration(minutes: 5);
  static const _maxCachedSearches = 24;

  @override
  String get id => source.id;

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    if (!source.capabilities.search) return const <Manga>[];
    final key = query.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (key.length < 2) return const <Manga>[];

    final cached = _searchCache.remove(key);
    if (cached != null &&
        DateTime.now().difference(cached.savedAt) < _searchTtl) {
      _searchCache[key] = cached;
      return cached.values;
    }

    final active = _searching[key];
    if (active != null && active.cancelToken?.isCancelled != true) {
      return active.future;
    }

    final future = _search(query, key, cancelToken: cancelToken);
    _searching[key] = (future: future, cancelToken: cancelToken);
    try {
      return await future;
    } finally {
      if (identical(_searching[key]?.future, future)) _searching.remove(key);
    }
  }

  Future<List<Manga>> _search(
    String query,
    String key, {
    CancelToken? cancelToken,
  }) async {
    final results = <String, Manga>{};
    for (final manga in await source.search(query, cancelToken: cancelToken)) {
      final mapped = _withStableMapping(manga);
      if (mapped == null || !mapped.isFriendlyContent) continue;
      final sourceId = mapped.allSourceMappings[id]!;
      results[sourceId] = mapped;
      _cache[sourceId] = mapped;
    }
    final values = List<Manga>.unmodifiable(results.values);
    _searchCache[key] = (savedAt: DateTime.now(), values: values);
    while (_searchCache.length > _maxCachedSearches) {
      _searchCache.remove(_searchCache.keys.first);
    }
    return values;
  }

  @override
  Future<Manga?> getById(String rawId) async {
    final sourceId = _sourceId(rawId);
    if (sourceId == null) return null;
    final loaded = await source.getMangaDetails(sourceId);
    final mapped = loaded == null
        ? _cache[sourceId]
        : _withStableMapping(loaded, sourceId: sourceId);
    return mapped?.isFriendlyContent == true ? mapped : null;
  }

  Manga? _withStableMapping(Manga manga, {String? sourceId}) {
    final resolved =
        sourceId ?? manga.allSourceMappings[id]?.trim() ?? _sourceId(manga.id);
    if (resolved == null || resolved.isEmpty) return null;
    return manga.copyWith(
      metadataProviderIds: {...manga.metadataProviderIds, id: resolved},
      sourceMappings: {...manga.sourceMappings, id: resolved},
    );
  }

  String? _sourceId(String rawId) {
    var value = rawId.trim();
    if (value.startsWith('tsuki:$id:')) {
      value = value.substring('tsuki:$id:'.length);
    } else if (value.startsWith('$id:')) {
      value = value.substring('$id:'.length);
    }
    return value.isEmpty ? null : value;
  }
}
