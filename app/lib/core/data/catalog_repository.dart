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
  })  : _comicK =
            comicK ??
                ComicKSource(),
        _mangaPill =
            mangaPill ??
                MangaPillSource(),
        _weebCentral =
            weebCentral ??
                WeebCentralSource(),
        _asura =
            asura ??
                AsuraSource() {
    if (_config.useDemoData) {
      for (final manga
          in demoCatalog) {
        _cache[manga.id] =
            manga;
      }
    }
  }

  final AppConfig _config;

  final MetadataProvider _metadata;

  final MangaDexSource _mangaDex;
  final ComicKSource _comicK;
  final MangaPillSource _mangaPill;
  final WeebCentralSource
      _weebCentral;
  final AsuraSource _asura;

  final Map<String, Manga>
      _cache = {};

  final Map<String,
          List<CanonicalChapter>>
      _chapterCache = {};

  /*
   * Successful source mappings only.
   *
   * Null misses are deliberately NOT cached.
   */
  final Map<String, String>
      _sourceMatchCache = {};

  /*
   * Sources run concurrently.
   *
   * Ten seconds is a maximum for a single
   * provider, not ten seconds multiplied by
   * five sources.
   */
  static const _sourceTimeout =
      Duration(seconds: 10);

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
        includeAdult:
            includeAdult,
      );

      for (final value in values) {
        _cache[value.id] =
            value;
      }

      return _dedupe(values);
    } catch (_) {
      if (!_config.useDemoData) {
        rethrow;
      }

      final normalized =
          query.toLowerCase();

      return demoCatalog
          .where(
            (manga) =>
                manga.title
                    .toLowerCase()
                    .contains(
                      normalized,
                    ),
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
        await _metadata.getById(
      id,
    );

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

    if (!refresh) {
      final cached =
          _chapterCache[
              cacheKey];

      if (cached != null) {
        return cached;
      }
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
      final values =
          demoChapters(
        manga,
      );

      _chapterCache[cacheKey] =
          values;

      return values;
    }

    /*
     * Every source is independent.
     *
     * Failure of MangaDex does not suppress
     * ComicK / WeebCentral / Asura / MangaPill.
     */
    final batches =
        await Future.wait<
            List<CanonicalChapter>>(
      [
        _safe(
          () => _loadMangaDex(
            manga,
          ),
        ),
        _safe(
          () => _loadComicK(
            manga,
          ),
        ),
        _safe(
          () => _loadWeebCentral(
            manga,
          ),
        ),
        _safe(
          () => _loadAsura(
            manga,
          ),
        ),
        _safe(
          () => _loadMangaPill(
            manga,
          ),
        ),
      ],
    );

    final collected =
        <CanonicalChapter>[];

    for (final batch in batches) {
      collected.addAll(batch);
    }

    final merged =
        _mergeChapters(
      collected,
    );

    final existing =
        _cache[manga.id] ??
            manga;

    _cache[manga.id] =
        existing.copyWith(
      chapterCount:
          merged.length,
    );

    _chapterCache[cacheKey] =
        merged;

    return merged;
  }

  Future<List<CanonicalChapter>>
      _safe(
    Future<List<CanonicalChapter>>
            Function()
        operation,
  ) async {
    try {
      return await operation()
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

    final existing =
        _cache[manga.id] ??
            manga;

    _cache[manga.id] =
        existing.copyWith(
      mangaDexId: sourceId,
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

  Future<String?> _resolve(
    String cacheKey,
    Future<String?> Function()
        resolver,
  ) async {
    final existing =
        _sourceMatchCache[
            cacheKey];

    if (existing != null) {
      return existing;
    }

    final result =
        await resolver();

    /*
     * Do not cache misses.
     *
     * Temporary source/search failures should be
     * retried next time.
     */
    if (result != null) {
      _sourceMatchCache[
          cacheKey] = result;
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
    List<CanonicalChapter>
        chapters,
  ) {
    final merged =
        <String,
            CanonicalChapter>{};

    for (final chapter
        in chapters) {
      final number =
          chapter.number;

      if (number != null &&
          (!number.isFinite ||
              number < 0 ||
              number > 20000)) {
        continue;
      }

      final key =
          number == null
              ? 'special:'
                  '${_normalize(chapter.title)}'
              : 'number:'
                  '${_numberLabel(number)}';

      /*
       * A special with no usable title cannot be
       * safely deduplicated.
       */
      if (number == null &&
          _normalize(
            chapter.title,
          ).isEmpty) {
        continue;
      }

      final existing =
          merged[key];

      if (existing == null) {
        final copies = [
          ...chapter.sourceCopies,
        ]..sort(
            (a, b) =>
                b.reliability
                    .compareTo(
              a.reliability,
            ),
          );

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
          sourceCopies: copies,
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

      final sortedCopies =
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
        title: _bestTitle(
          existing.title,
          chapter.title,
        ),
        publishedAt:
            _earliestMeaningfulDate(
          existing.publishedAt,
          chapter.publishedAt,
        ),
        sourceCopies:
            sortedCopies,
      );
    }

    final values =
        merged.values.toList()
          ..sort(
            (a, b) {
              final left =
                  a.number;

              final right =
                  b.number;

              if (left != null &&
                  right != null) {
                return left
                    .compareTo(right);
              }

              if (left != null) {
                return -1;
              }

              if (right != null) {
                return 1;
              }

              return a.title
                  .compareTo(
                b.title,
              );
            },
          );

    return values;
  }

  String _bestTitle(
    String left,
    String right,
  ) {
    final generic =
        RegExp(
      r'^(?:chapter|ch\.?)\s*#?\s*\d+(?:\.\d+)?$',
      caseSensitive: false,
    );

    final leftGeneric =
        generic.hasMatch(
      left.trim(),
    );

    final rightGeneric =
        generic.hasMatch(
      right.trim(),
    );

    if (leftGeneric &&
        !rightGeneric) {
      return right;
    }

    if (!leftGeneric &&
        rightGeneric) {
      return left;
    }

    return right.length >
            left.length
        ? right
        : left;
  }

  DateTime _earliestMeaningfulDate(
    DateTime left,
    DateTime right,
  ) {
    final epoch =
        DateTime
            .fromMillisecondsSinceEpoch(
      0,
    );

    if (left == epoch) {
      return right;
    }

    if (right == epoch) {
      return left;
    }

    return left.isBefore(right)
        ? left
        : right;
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
      if (!copy
          .isDirectlyReadable) {
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
        /*
         * Automatically try the next copy.
         */
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
      final key =
          manga.anilistId
                  ?.toString() ??
              _normalize(
                manga.title,
              );

      map.putIfAbsent(
        key,
        () => manga,
      );
    }

    return map.values
        .toList();
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