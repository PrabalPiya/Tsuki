import 'dart:math' as math;

import '../config/app_config.dart';
import '../models/chapter.dart';
import '../models/manga.dart';

import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/comick_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangapill_source.dart';
import '../../features/reader/data/weebcentral_source.dart';

import '../../features/search/data/metadata_provider.dart';
import '../../shared/demo_catalog.dart';

class CatalogRepository {
  CatalogRepository({
    required this._config,
    required this._metadata,
    required this._mangaDex,
    ComicKSource? comicK,
    MangaPillSource? mangaPill,
    WeebCentralSource? weebCentral,
    AsuraSource? asura,
  })  : _comicK = comicK ?? ComicKSource(),
        _mangaPill = mangaPill ?? MangaPillSource(),
        _weebCentral = weebCentral ?? WeebCentralSource(),
        _asura = asura ?? AsuraSource() {
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
  final AsuraSource _asura;

  final Map<String, Manga> _cache = {};

  final Map<String, List<CanonicalChapter>>
      _chapterCache = {};

  final Map<String, String>
      _sourceMatchCache = {};

  static const _sourceTimeout =
      Duration(seconds: 8);

  List<Manga> get demoRankings =>
      _config.useDemoData
          ? demoCatalog
          : const [];

  Manga? cached(String id) =>
      _cache[id];

  void remember(Manga manga) {
    _cache[manga.id] = manga;
  }

  Future<List<Manga>> search(
    String query, {
    required bool includeAdult,
  }) async {
    if (query.trim().length < 2) {
      return const [];
    }

    try {
      final values =
          await _metadata.search(
        query.trim(),
        includeAdult: includeAdult,
      );

      for (final value in values) {
        _cache[value.id] = value;
      }

      return _dedupe(values);
    } catch (_) {
      if (!_config.useDemoData) {
        rethrow;
      }

      final q =
          query.toLowerCase();

      return demoCatalog
          .where(
            (manga) =>
                manga.title
                    .toLowerCase()
                    .contains(q),
          )
          .toList();
    }
  }

  Future<Manga?> details(
    String id,
  ) async {
    final value =
        _cache[id];

    if (value != null) {
      return value;
    }

    final loaded =
        await _metadata.getById(id);

    if (loaded != null) {
      _cache[id] = loaded;
    }

    return loaded;
  }

  Future<List<CanonicalChapter>>
      chapters(
    Manga manga, {
    bool refresh = false,
    bool allowAdult = false,
  }) async {
    if (manga.isAdult &&
        !allowAdult) {
      return const [];
    }

    final cacheKey =
        '${manga.id}|adult:$allowAdult';

    if (!refresh &&
        _chapterCache
            .containsKey(cacheKey)) {
      return _chapterCache[
          cacheKey]!;
    }

    if (refresh) {
      _chapterCache.remove(
        cacheKey,
      );

      _clearMatches(
        manga.id,
      );
    }

    if (manga.id.startsWith(
      'demo:',
    )) {
      final result =
          demoChapters(manga);

      _chapterCache[
          cacheKey] = result;

      return result;
    }

    /*
     * IMPORTANT:
     *
     * All sources now run IN PARALLEL.
     *
     * Before:
     *
     * MangaDex
     *   wait
     * ComicK
     *   wait
     * MangaPill
     *   wait
     * WeebCentral
     *   wait
     * Asura
     *
     * Now:
     *
     * MangaDex ─────┐
     * ComicK ───────┤
     * MangaPill ────┤
     * WeebCentral ──┤
     * Asura ─────────┘
     */
    final batches =
        await Future.wait([
      _safeSource(
        () => _loadMangaDex(
          manga,
        ),
      ),
      _safeSource(
        () => _loadComicK(
          manga,
        ),
      ),
      _safeSource(
        () => _loadMangaPill(
          manga,
        ),
      ),
      _safeSource(
        () => _loadWeebCentral(
          manga,
        ),
      ),
      _safeSource(
        () => _loadAsura(
          manga,
        ),
      ),
    ]);

    final collected =
        <CanonicalChapter>[];

    for (final batch in batches) {
      collected.addAll(batch);
    }

    final merged =
        _mergeChapters(
      collected,
      manga,
    );

    final current =
        _cache[manga.id] ??
            manga;

    _cache[manga.id] =
        current.copyWith(
      chapterCount:
          merged.length,
    );

    _chapterCache[
        cacheKey] = merged;

    return merged;
  }

  Future<List<CanonicalChapter>>
      _safeSource(
    Future<List<CanonicalChapter>>
            Function()
        loader,
  ) async {
    try {
      return await loader()
          .timeout(
        _sourceTimeout,
      );
    } catch (_) {
      return const [];
    }
  }

  Future<List<CanonicalChapter>>
      _loadMangaDex(
    Manga manga,
  ) async {
    final sourceId =
        manga.mangaDexId ??
            await _resolve(
              '${manga.id}|mangadex',
              () => _mangaDex
                  .findConservativeMatch(
                manga,
              ),
            );

    if (sourceId == null) {
      return const [];
    }

    final values =
        await _mangaDex
            .getChapters(
      sourceId,
    );

    final current =
        _cache[manga.id] ??
            manga;

    _cache[manga.id] =
        current.copyWith(
      mangaDexId:
          sourceId,
    );

    return values;
  }

  Future<List<CanonicalChapter>>
      _loadComicK(
    Manga manga,
  ) async {
    final sourceId =
        await _resolve(
      '${manga.id}|comick',
      () => _comicK
          .findConservativeMatch(
        manga,
      ),
    );

    if (sourceId == null) {
      return const [];
    }

    return _comicK
        .getChapters(
      sourceId,
    );
  }

  Future<List<CanonicalChapter>>
      _loadMangaPill(
    Manga manga,
  ) async {
    final sourceId =
        await _resolve(
      '${manga.id}|mangapill',
      () => _mangaPill
          .findConservativeMatch(
        manga,
      ),
    );

    if (sourceId == null) {
      return const [];
    }

    return _mangaPill
        .getChapters(
      sourceId,
    );
  }

  Future<List<CanonicalChapter>>
      _loadWeebCentral(
    Manga manga,
  ) async {
    final sourceId =
        await _resolve(
      '${manga.id}|weebcentral',
      () => _weebCentral
          .findConservativeMatch(
        manga,
      ),
    );

    if (sourceId == null) {
      return const [];
    }

    return _weebCentral
        .getChapters(
      sourceId,
    );
  }

  Future<List<CanonicalChapter>>
      _loadAsura(
    Manga manga,
  ) async {
    final sourceId =
        await _resolve(
      '${manga.id}|asura',
      () => _asura
          .findConservativeMatch(
        manga,
      ),
    );

    if (sourceId == null) {
      return const [];
    }

    return _asura
        .getChapters(
      sourceId,
    );
  }

  Future<String?> _resolve(
    String key,
    Future<String?> Function()
        resolver,
  ) async {
    final cached =
        _sourceMatchCache[key];

    if (cached != null) {
      return cached;
    }

    final result =
        await resolver();

    /*
     * IMPORTANT:
     *
     * Do NOT cache null.
     *
     * A temporary search/source failure should
     * not permanently mean "this manga does not
     * exist on this source".
     */
    if (result != null) {
      _sourceMatchCache[key] =
          result;
    }

    return result;
  }

  void _clearMatches(
    String mangaId,
  ) {
    final keys =
        _sourceMatchCache.keys
            .where(
              (key) =>
                  key.startsWith(
                '$mangaId|',
              ),
            )
            .toList();

    for (final key in keys) {
      _sourceMatchCache.remove(
        key,
      );
    }
  }

  List<CanonicalChapter>
      _mergeChapters(
    List<CanonicalChapter> input,
    Manga manga,
  ) {
    final merged =
        <String,
            CanonicalChapter>{};

    for (final chapter in input) {
      /*
       * Remove obviously corrupted chapter
       * numbers BEFORE merging.
       */
      if (!_reasonableChapter(
        chapter,
        manga,
      )) {
        continue;
      }

      final key =
          chapter.number != null
              ? 'number:'
                  '${_numberLabel(chapter.number!)}'
              : 'special:'
                  '${_normalize(chapter.title)}';

      final existing =
          merged[key];

      if (existing == null) {
        merged[key] =
            CanonicalChapter(
          id:
              'chapter:$key',
          number:
              chapter.number,
          title:
              chapter.title,
          publishedAt:
              chapter.publishedAt,
          sourceCopies: [
            ...chapter.sourceCopies,
          ],
        );

        continue;
      }

      final copies =
          <String,
              ChapterSourceCopy>{};

      for (final copy in [
        ...existing.sourceCopies,
        ...chapter.sourceCopies,
      ]) {
        copies[
                '${copy.sourceId}|'
                '${copy.chapterId}'] =
            copy;
      }

      final sorted =
          copies.values.toList()
            ..sort(
              (a, b) =>
                  b.reliability
                      .compareTo(
                a.reliability,
              ),
            );

      merged[key] =
          CanonicalChapter(
        id: existing.id,
        number:
            existing.number ??
                chapter.number,
        title: _betterTitle(
          existing.title,
          chapter.title,
        ),
        publishedAt:
            chapter.publishedAt
                    .isBefore(
              existing.publishedAt,
            )
                ? chapter
                    .publishedAt
                : existing
                    .publishedAt,
        sourceCopies: sorted,
      );
    }

    final result =
        merged.values.toList()
          ..sort(
            (a, b) {
              if (a.number != null &&
                  b.number != null) {
                return a.number!
                    .compareTo(
                  b.number!,
                );
              }

              if (a.number != null) {
                return -1;
              }

              if (b.number != null) {
                return 1;
              }

              return a.title
                  .compareTo(
                b.title,
              );
            },
          );

    return result;
  }

  bool _reasonableChapter(
    CanonicalChapter chapter,
    Manga manga,
  ) {
    final number =
        chapter.number;

    /*
     * Specials without a chapter number are OK.
     */
    if (number == null) {
      return chapter.title
          .trim()
          .isNotEmpty;
    }

    if (!number.isFinite ||
        number < 0) {
      return false;
    }

    /*
     * Absolute protection against accidentally
     * parsing database IDs / years / timestamps.
     */
    if (number > 10000) {
      return false;
    }

    /*
     * AniList knows total chapters for many
     * completed series.
     *
     * Give sources LOTS of tolerance because
     * AniList can be stale/different.
     */
    if (manga.chapterCount > 0) {
      final expected =
          manga.chapterCount;

      final maximum =
          math.max(
        expected * 2.0,
        expected + 100.0,
      );

      if (number > maximum) {
        return false;
      }
    }

    return true;
  }

  String _betterTitle(
    String current,
    String candidate,
  ) {
    final pattern =
        RegExp(
      r'^Chapter\s+\d+(?:\.\d+)?$',
      caseSensitive: false,
    );

    if (pattern.hasMatch(
          current.trim(),
        ) &&
        !pattern.hasMatch(
          candidate.trim(),
        )) {
      return candidate;
    }

    return current;
  }

  Future<ChapterPages> pages(
    CanonicalChapter chapter,
  ) async {
    final copies = [
      ...chapter.sourceCopies,
    ]..sort(
        (a, b) =>
            b.reliability
                .compareTo(
          a.reliability,
        ),
      );

    Object? lastError;

    for (final copy in copies) {
      if (!copy.isDirectlyReadable) {
        continue;
      }

      try {
        if (copy.sourceId ==
            'demo') {
          return demoPages(
            copy.chapterId,
          );
        }

        if (copy.sourceId ==
            _mangaDex.id) {
          return await _mangaDex
              .getChapterPages(
            copy.chapterId,
          );
        }

        if (copy.sourceId ==
            _comicK.id) {
          return await _comicK
              .getChapterPages(
            copy.chapterId,
          );
        }

        if (copy.sourceId ==
            _weebCentral.id) {
          return await _weebCentral
              .getChapterPages(
            copy.chapterId,
          );
        }

        if (copy.sourceId ==
            _asura.id) {
          return await _asura
              .getChapterPages(
            copy.chapterId,
          );
        }

        if (copy.sourceId ==
            _mangaPill.id) {
          return await _mangaPill
              .getChapterPages(
            copy.chapterId,
          );
        }
      } catch (error) {
        lastError = error;
      }
    }

    throw lastError ??
        StateError(
          'Chapter unavailable right now.',
        );
  }

  List<Manga> _dedupe(
    List<Manga> values,
  ) {
    final map =
        <String, Manga>{};

    for (final manga in values) {
      map.putIfAbsent(
        manga.anilistId
                ?.toString() ??
            _normalize(
              manga.title,
            ),
        () => manga,
      );
    }

    return map.values.toList();
  }

  String _normalize(
    String value,
  ) =>
      value
          .toLowerCase()
          .replaceAll(
            RegExp(
              r'[^a-z0-9]',
            ),
            '',
          );

  String _numberLabel(
    double value,
  ) =>
      value ==
              value.roundToDouble()
          ? value.toInt().toString()
          : value.toString();
}