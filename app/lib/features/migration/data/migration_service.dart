// ignore_for_file: prefer_initializing_formals

import '../../../core/data/catalog_repository.dart';
import '../../../core/identity/manga_identity_resolver.dart';
import '../../../core/models/manga.dart';
import '../../../core/models/reading_progress.dart';
import '../../../core/state/app_state.dart';
import '../../../core/storage/canonical_alias_index.dart';
import '../../../core/storage/manga_metadata_cache.dart';
import 'migration_models.dart';
import 'import_session_repository.dart';

class ImportMatch {
  const ImportMatch({
    required this.entry,
    required this.status,
    this.manga,
    this.candidates = const [],
    this.confidence = 0,
  });

  final ImportedMangaEntry entry;
  final ImportMatchStatus status;
  final Manga? manga;
  final List<Manga> candidates;
  final double confidence;
}

class ImportPreview {
  const ImportPreview({required this.document, required this.matches});
  final MigrationDocument document;
  final List<ImportMatch> matches;

  int count(ImportMatchStatus status) =>
      matches.where((match) => match.status == status).length;
}

class MigrationService {
  MigrationService({
    required CatalogRepository catalog,
    required MangaMetadataCache cache,
    required CanonicalAliasIndex aliases,
    ImportSessionRepository? sessions,
    MangaIdentityResolver resolver = const MangaIdentityResolver(),
  }) : _catalog = catalog,
       _cache = cache,
       _aliases = aliases,
       _sessions = sessions ?? ImportSessionRepository(),
       _resolver = resolver;

  final CatalogRepository _catalog;
  final MangaMetadataCache _cache;
  final CanonicalAliasIndex _aliases;
  final ImportSessionRepository _sessions;
  final MangaIdentityResolver _resolver;

  static const _reviewScoreThreshold = .18;

  Future<ImportPreview> prepare(
    String raw, {
    void Function(int completed, int total)? onProgress,
    Map<String, ReadingProgress> existingProgress = const {},
  }) async {
    final document = const MigrationValidator().decode(raw);
    final local = await _cache.loadIndex();
    final results = List<ImportMatch?>.filled(document.entries.length, null);
    final unresolved = <int>[];

    for (var index = 0; index < document.entries.length; index++) {
      final entry = document.entries[index];
      results[index] = _withProgressConflict(
        await _matchLocal(entry, local),
        existingProgress,
      );
      if (results[index] == null) unresolved.add(index);
      onProgress?.call(index + 1 - unresolved.length, document.entries.length);
    }

    var cursor = 0;
    Future<void> worker() async {
      while (cursor < unresolved.length) {
        final index = unresolved[cursor++];
        results[index] = _withProgressConflict(
          await _matchRemote(document.entries[index]),
          existingProgress,
        );
        onProgress?.call(
          results.whereType<ImportMatch>().length,
          document.entries.length,
        );
      }
    }

    await Future.wait(
      List.generate(unresolved.length.clamp(0, 4), (_) => worker()),
    );
    return ImportPreview(
      document: document,
      matches: results.whereType<ImportMatch>().toList(growable: false),
    );
  }

  Future<ImportMatch?> _matchLocal(
    ImportedMangaEntry entry,
    List<Manga> local,
  ) async {
    final knownId = await _aliases.lookup(
      source: entry.source,
      sourceId: entry.sourceMangaId,
    );
    if (knownId != null) {
      final known = local
          .where((manga) => manga.tsukiId == knownId)
          .firstOrNull;
      if (known != null) {
        return ImportMatch(
          entry: entry,
          status: ImportMatchStatus.matched,
          manga: known,
          confidence: 1,
        );
      }
    }
    return _best(entry, local, localOnly: true);
  }

  Future<ImportMatch> _matchRemote(ImportedMangaEntry entry) async {
    try {
      final direct = await _catalog.resolveImportedSource(
        source: entry.source,
        sourceMangaId: entry.sourceMangaId,
        sourceUrl: entry.sourceUrl,
      );
      if (direct != null) {
        return ImportMatch(
          entry: entry,
          status: ImportMatchStatus.matched,
          manga: direct,
          confidence: 1,
        );
      }
    } catch (_) {
      // Unsupported or temporarily unavailable sources continue by title.
    }

    final candidates = <String, Manga>{};
    var completedSearch = false;
    final queries = _searchQueries(entry);

    for (final query in queries) {
      try {
        final results = await _catalog.searchMetadataOnly(query);
        completedSearch = true;
        for (final manga in results) {
          candidates[manga.tsukiId] = manga;
        }
      } catch (_) {
        // One title spelling or metadata provider can fail independently.
      }
    }

    if (!completedSearch) {
      return ImportMatch(entry: entry, status: ImportMatchStatus.error);
    }
    return _best(
          entry,
          candidates.values.toList(growable: false),
          localOnly: false,
        ) ??
        ImportMatch(entry: entry, status: ImportMatchStatus.unmatched);
  }

  ImportMatch? _best(
    ImportedMangaEntry entry,
    List<Manga> candidates, {
    required bool localOnly,
  }) {
    final imported = Manga(
      id: 'import:${entry.sourceKey}',
      title: entry.title,
      aliases: <String>{
        ...entry.aliases,
        ..._searchQueries(entry),
      }.toList(growable: false),
      authors: [if (entry.author != null) entry.author!],
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.unknown,
      chapterCount: 0,
    );
    final scored =
        candidates
            .map(
              (manga) =>
                  (manga: manga, match: _resolver.compare(imported, manga)),
            )
            .where(
              (value) =>
                  value.match.confidence != MatchConfidence.low ||
                  value.match.score >= _reviewScoreThreshold,
            )
            .toList()
          ..sort((a, b) => b.match.score.compareTo(a.match.score));
    if (scored.isEmpty) return null;
    final best = scored.first;
    if (best.match.canMerge) {
      return ImportMatch(
        entry: entry,
        status: ImportMatchStatus.matched,
        manga: best.manga,
        confidence: best.match.score,
      );
    }
    if (localOnly) return null;
    return ImportMatch(
      entry: entry,
      status: ImportMatchStatus.needsReview,
      candidates: scored.take(3).map((value) => value.manga).toList(),
      confidence: best.match.score,
    );
  }

  List<String> _searchQueries(ImportedMangaEntry entry) {
    final queries = <String>{};

    void add(String raw) {
      final value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.length >= 2 && value.length <= 300) queries.add(value);
    }

    for (final raw in <String>[entry.title, ...entry.aliases]) {
      add(raw);
      final cleaned = raw
          .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
          .replaceAll('&amp;', '&')
          .replaceFirst(
            RegExp(r'^\s*(?:read|watch)\s+', caseSensitive: false),
            '',
          )
          .replaceAll(
            RegExp(
              r'\s*[\[(](?:completed|ongoing|official|english|webtoon|manga|manhwa)[\])]\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(
            RegExp(
              r'\s*[-|]\s*(?:mangakakalot|demonic\s+scans?|mangadex|mangakatana|asura(?:\s+scans?)?|weeb\s*central)\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(
            RegExp(
              r'\s*(?:[-|:]\s*)?(?:read\s+)?(?:manga|manhwa|manhua|webtoon|comic)(?:\s+online)?\s*$',
              caseSensitive: false,
            ),
            '',
          )
          .replaceAll(
            RegExp(
              r'\s+(?:chapter|ch\.?|episode|ep\.?)\s*[:#-]?\s*\d+(?:\.\d+)?(?:\s.*)?$',
              caseSensitive: false,
            ),
            '',
          );
      add(cleaned);
    }

    final uri = Uri.tryParse(entry.sourceUrl ?? '');
    if (uri != null) {
      final segments = uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .toList(growable: false);
      if (segments.isNotEmpty) {
        var slug = Uri.decodeComponent(segments.last);
        if (RegExp(r'^\d+$').hasMatch(slug) && segments.length > 1) {
          slug = Uri.decodeComponent(segments[segments.length - 2]);
        }
        add(
          slug
              .replaceAll(RegExp(r'[-_]+'), ' ')
              .replaceAll(RegExp(r'\.\d+$'), ''),
        );
      }
    }
    return queries.take(8).toList(growable: false);
  }

  ImportMatch? _withProgressConflict(
    ImportMatch? match,
    Map<String, ReadingProgress> existing,
  ) {
    final manga = match?.manga;
    if (match == null || manga == null) return match;
    final saved = existing[manga.id];
    if (saved == null || match.entry.rawChapter == null) return match;
    final incomingNumber = match.entry.normalizedChapterNumber;
    final savedNumber =
        saved.normalizedChapterNumber ?? _numberFromChapterId(saved.chapterId);
    if (incomingNumber != null || savedNumber == null) return match;
    return ImportMatch(
      entry: match.entry,
      status: ImportMatchStatus.conflict,
      manga: manga,
      candidates: match.candidates,
      confidence: match.confidence,
    );
  }

  Future<void> commit(
    ImportPreview preview,
    UserLibraryController library, {
    void Function(int completed, int total)? onEnrichmentProgress,
  }) async {
    final manga = <String, Manga>{};
    final preferredSources = <String, String>{};
    final progress = <String, ReadingProgress>{};
    for (final match in preview.matches) {
      final importedCandidate = match.manga;
      if ((match.status != ImportMatchStatus.matched &&
              match.status != ImportMatchStatus.conflict) ||
          importedCandidate == null ||
          !importedCandidate.isFriendlyContent) {
        continue;
      }
      final verified = await _catalog.verifyForOpen(importedCandidate);
      if (verified == null) continue;
      var value = verified;
      for (final existing in library.currentState.bookmarkedManga.values) {
        if (!_resolver.compare(existing, value).canMerge) continue;
        value = _resolver.merge(existing, value).copyWith(id: existing.id);
        break;
      }
      final importedSourceId =
          value.allSourceMappings[match.entry.source] ??
          match.entry.sourceMangaId;
      final importedManga = value.copyWith(
        sourceMappings: {
          ...value.sourceMappings,
          match.entry.source: importedSourceId,
        },
      );
      manga[value.id] = importedManga;
      preferredSources[value.id] = match.entry.source;
      await _aliases.learn(importedManga);
      final number = match.entry.normalizedChapterNumber;
      if (match.entry.rawChapter == null ||
          match.status == ImportMatchStatus.conflict) {
        continue;
      }
      final candidate = ReadingProgress(
        mangaId: value.id,
        chapterId: number == null
            ? 'chapter:import:${match.entry.rawChapter}'
            : 'chapter:number:${_numberLabel(number)}',
        pageIndex: 0,
        relativeOffset: 0,
        chapterProgress: 1,
        rawChapter: match.entry.rawChapter,
        normalizedChapterNumber: number,
        updatedAt: DateTime.now(),
      );
      final previous = progress[value.id];
      if (previous == null ||
          (number != null &&
              (previous.normalizedChapterNumber == null ||
                  number > previous.normalizedChapterNumber!))) {
        progress[value.id] = candidate;
      }
    }

    // Populate the same live chapter indexes used by Details before exposing
    // imported bookmarks to Home. Keep concurrency bounded so a large import
    // cannot flood the device or the external manga sources.
    final imported = manga.values.toList(growable: false);
    var completed = 0;
    var cursor = 0;
    onEnrichmentProgress?.call(completed, imported.length);

    Future<void> worker() async {
      while (cursor < imported.length) {
        final item = imported[cursor++];
        try {
          await _catalog.prewarmImportedChapters(
            item,
            preferredSource: preferredSources[item.id] ?? '',
          );
        } catch (_) {
          // One unavailable source/title must not cancel the whole import.
        } finally {
          completed++;
          onEnrichmentProgress?.call(completed, imported.length);
        }
      }
    }

    await Future.wait(
      List.generate(imported.length.clamp(0, 6), (_) => worker()),
    );

    await library.importBatch(manga, progress);
    await _sessions.record(
      document: preview.document,
      matchedCount: preview.count(ImportMatchStatus.matched),
      needsReviewCount: preview.count(ImportMatchStatus.needsReview),
      unmatchedCount: preview.count(ImportMatchStatus.unmatched),
      conflictCount: preview.count(ImportMatchStatus.conflict),
      errorCount: preview.count(ImportMatchStatus.error),
      mangaIds: manga.keys,
    );
  }

  String _numberLabel(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  double? _numberFromChapterId(String chapterId) {
    final match = RegExp(r'(?:^|:)number:([0-9]+(?:\.[0-9]+)?)$')
        .firstMatch(chapterId);
    return match == null ? null : double.tryParse(match.group(1)!);
  }
}
