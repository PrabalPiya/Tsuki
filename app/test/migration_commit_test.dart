import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/identity/manga_identity_resolver.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/models/reading_progress.dart';
import 'package:tsuki/core/state/app_state.dart';
import 'package:tsuki/core/storage/canonical_alias_index.dart';
import 'package:tsuki/core/storage/manga_metadata_cache.dart';
import 'package:tsuki/core/storage/user_store.dart';
import 'package:tsuki/features/migration/data/import_session_repository.dart';
import 'package:tsuki/features/migration/data/migration_models.dart';
import 'package:tsuki/features/migration/data/migration_service.dart';

class _Catalog extends Mock implements CatalogRepository {}

class _MetadataCache extends Mock implements MangaMetadataCache {}

class _FakeManga extends Fake implements Manga {}

class _Store implements UserStore {
  @override
  Future<UserSnapshot> load(String uid) async =>
      const UserSnapshot(bookmarks: {}, bookmarkedManga: {}, progress: {});

  @override
  Future<void> clearSession(String uid) async {}

  @override
  Future<void> saveBookmarks(
    String uid,
    Set<String> ids,
    Map<String, Manga> manga,
  ) async {}

  @override
  Future<void> saveProgress(String uid, ReadingProgress progress) async {}
}

class _RecordingLibrary extends UserLibraryController {
  _RecordingLibrary() : super('migration-test', _Store());

  Map<String, Manga> importedManga = const {};

  @override
  Future<void> importBatch(
    Map<String, Manga> manga,
    Map<String, ReadingProgress> progress,
  ) async {
    importedManga = manga;
  }
}

void main() {
  setUpAll(() => registerFallbackValue(_FakeManga()));

  test(
    'prepare retries exported alternate titles when the primary is wrong',
    () async {
      final catalog = _Catalog();
      final cache = _MetadataCache();
      const canonical = Manga(
        id: 'anilist:alternate',
        title: 'Correct Alternate Title',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      );
      when(() => cache.loadIndex()).thenAnswer((_) async => const []);
      when(() => catalog.searchMetadataOnly(any()))
          .thenAnswer((invocation) async {
            final query = invocation.positionalArguments.single as String;
            return query == canonical.title ? const [canonical] : const [];
          });
      final service = MigrationService(
        catalog: catalog,
        cache: cache,
        aliases: CanonicalAliasIndex(),
        sessions: ImportSessionRepository(),
      );

      final preview = await service.prepare(
        jsonEncode({
          'format': 'tsuki-migration',
          'schemaVersion': 1,
          'createdAt': '2026-08-29T00:00:00Z',
          'entries': [
            {
              'source': 'mangadex',
              'sourceMangaId': 'alternate-id',
              'title': 'Incorrect Display Title',
              'aliases': [canonical.title],
            },
          ],
        }),
      );

      expect(preview.matches.single.status, ImportMatchStatus.matched);
      expect(preview.matches.single.manga?.id, canonical.id);
      verify(() => catalog.searchMetadataOnly('Incorrect Display Title'))
          .called(1);
      verify(() => catalog.searchMetadataOnly(canonical.title)).called(1);
    },
  );

  test('similar low-confidence titles are offered for review', () async {
    final catalog = _Catalog();
    final cache = _MetadataCache();
    const candidate = Manga(
      id: 'anilist:similar',
      title: 'The Frozen Player Returns',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
    );
    when(() => cache.loadIndex()).thenAnswer((_) async => const []);
    when(() => catalog.searchMetadataOnly(any()))
        .thenAnswer((_) async => const [candidate]);
    final service = MigrationService(
      catalog: catalog,
      cache: cache,
      aliases: CanonicalAliasIndex(),
      sessions: ImportSessionRepository(),
    );

    final preview = await service.prepare(
      jsonEncode({
        'format': 'tsuki-migration',
        'schemaVersion': 1,
        'createdAt': '2026-08-29T00:00:00Z',
        'entries': [
          {
            'source': 'mangadex',
            'sourceMangaId': 'similar-id',
            'title': 'Return of Frozen Player',
          },
        ],
      }),
    );

    expect(preview.matches.single.status, ImportMatchStatus.needsReview);
    expect(preview.matches.single.candidates, const [candidate]);
  });

  test(
    'migration accepts a match supplied only by fallback metadata',
    () async {
      final catalog = _Catalog();
      final cache = _MetadataCache();
      const kitsuCandidate = Manga(
        id: 'tsuki:kitsu:42',
        kitsuId: '42',
        metadataProviderIds: {'kitsu': '42'},
        title: 'Fallback Work',
        coverUrl: '',
        synopsis: 'A safe fallback synopsis.',
        status: MangaStatus.ongoing,
        chapterCount: 12,
      );
      when(() => cache.loadIndex()).thenAnswer((_) async => const []);
      when(() => catalog.searchMetadataOnly(any()))
          .thenAnswer((_) async => const [kitsuCandidate]);
      final service = MigrationService(
        catalog: catalog,
        cache: cache,
        aliases: CanonicalAliasIndex(),
        sessions: ImportSessionRepository(),
      );

      final preview = await service.prepare(
        jsonEncode({
          'format': 'tsuki-migration',
          'schemaVersion': 1,
          'createdAt': '2026-08-29T00:00:00Z',
          'entries': [
            {
              'source': 'mangadex',
              'sourceMangaId': 'fallback-id',
              'title': 'Fallback Work',
            },
          ],
        }),
      );

      expect(preview.matches.single.status, ImportMatchStatus.matched);
      expect(preview.matches.single.manga, kitsuCandidate);
    },
  );

  test('migration prefers an exact supported source bookmark', () async {
    final catalog = _Catalog();
    final cache = _MetadataCache();
    const direct = Manga(
      id: 'mangakakalot:exact-work',
      metadataProviderIds: {'mangakakalot': 'exact-work'},
      sourceMappings: {'mangakakalot': 'exact-work'},
      title: 'Canonical Source Title',
      coverUrl: '',
      synopsis: 'A safe source synopsis.',
      status: MangaStatus.ongoing,
      chapterCount: 20,
    );
    when(() => cache.loadIndex()).thenAnswer((_) async => const []);
    when(
      () => catalog.resolveImportedSource(
        source: 'mangakakalot',
        sourceMangaId: 'exact-work',
        sourceUrl: 'https://www.mangakakalot.gg/manga/exact-work',
      ),
    ).thenAnswer((_) async => direct);
    final service = MigrationService(
      catalog: catalog,
      cache: cache,
      aliases: CanonicalAliasIndex(),
      sessions: ImportSessionRepository(),
    );

    final preview = await service.prepare(
      jsonEncode({
        'format': 'tsuki-migration',
        'schemaVersion': 1,
        'createdAt': '2026-08-29T00:00:00Z',
        'entries': [
          {
            'source': 'mangakakalot',
            'sourceMangaId': 'exact-work',
            'sourceUrl': 'https://www.mangakakalot.gg/manga/exact-work',
            'title': 'Read Canonical Source Title Manga Online',
          },
        ],
      }),
    );

    expect(preview.matches.single.status, ImportMatchStatus.matched);
    expect(preview.matches.single.manga, direct);
    verifyNever(() => catalog.searchMetadataOnly(any()));
  });

  test('migration searches a cleaned exported title', () async {
    final catalog = _Catalog();
    final cache = _MetadataCache();
    const candidate = Manga(
      id: 'anilist:clean-title',
      anilistId: 500,
      title: 'The Clean Title',
      coverUrl: '',
      synopsis: 'A safe canonical synopsis.',
      status: MangaStatus.ongoing,
      chapterCount: 5,
    );
    when(() => cache.loadIndex()).thenAnswer((_) async => const []);
    when(
      () => catalog.resolveImportedSource(
        source: any(named: 'source'),
        sourceMangaId: any(named: 'sourceMangaId'),
        sourceUrl: any(named: 'sourceUrl'),
      ),
    ).thenAnswer((_) async => null);
    when(() => catalog.searchMetadataOnly(any()))
        .thenAnswer((invocation) async {
          final query = invocation.positionalArguments.single as String;
          return query == candidate.title ? const [candidate] : const [];
        });
    final service = MigrationService(
      catalog: catalog,
      cache: cache,
      aliases: CanonicalAliasIndex(),
      sessions: ImportSessionRepository(),
    );

    final preview = await service.prepare(
      jsonEncode({
        'format': 'tsuki-migration',
        'schemaVersion': 1,
        'createdAt': '2026-08-29T00:00:00Z',
        'entries': [
          {
            'source': 'comick',
            'sourceMangaId': 'clean-title',
            'title': 'Read The Clean Title Manga Online',
          },
        ],
      }),
    );

    expect(preview.matches.single.status, ImportMatchStatus.matched);
    expect(preview.matches.single.manga, candidate);
    verify(() => catalog.searchMetadataOnly(candidate.title)).called(1);
  });

  test(
    'commit persists the exported source mapping on imported bookmarks',
    () async {
      const manga = Manga(
        id: 'anilist:1',
        title: 'Imported title',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      );
      const entry = ImportedMangaEntry(
        source: 'mangadex',
        sourceMangaId: 'source-title-id',
        title: 'Imported title',
        aliases: [],
        rawChapter: null,
        normalizedChapterNumber: null,
      );
      final preview = ImportPreview(
        document: MigrationDocument(
          createdAt: DateTime(2026),
          sources: const ['mangadex'],
          entries: const [entry],
          validationErrors: const [],
        ),
        matches: const [
          ImportMatch(
            entry: entry,
            status: ImportMatchStatus.matched,
            manga: manga,
            confidence: 1,
          ),
        ],
      );
      final library = _RecordingLibrary();
      final catalog = _Catalog();
      when(() => catalog.verifyForOpen(any())).thenAnswer(
        (invocation) async => invocation.positionalArguments.single as Manga,
      );
      when(
        () => catalog.prewarmImportedChapters(
          any(),
          preferredSource: any(named: 'preferredSource'),
        ),
      ).thenAnswer((_) async {});
      final service = MigrationService(
        catalog: catalog,
        cache: _MetadataCache(),
        aliases: CanonicalAliasIndex(),
        sessions: ImportSessionRepository(),
        resolver: const MangaIdentityResolver(),
      );

      final importedCount = await service.commit(preview, library);

      expect(importedCount, 1);
      expect(library.importedManga[manga.id]?.sourceMappings, const {
        'mangadex': 'source-title-id',
      });
      verify(
        () => catalog.prewarmImportedChapters(
          any(that: isA<Manga>()),
          preferredSource: 'mangadex',
        ),
      ).called(1);
      library.dispose();
    },
  );
}
