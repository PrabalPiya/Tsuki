import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/manga_source.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/manga_source_metadata_provider.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';

const _config = AppConfig(
  environment: AppEnvironment.development,
  useDemoData: false,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
  remoteCatalogUrl: '',
);

class _Source implements MangaSource {
  _Source(
    this.id,
    this.sourceMangaId, {
    this.gate,
    this.unsafe = false,
    this.detailsUnavailable = false,
  });

  @override
  final String id;
  final String sourceMangaId;
  final Completer<void>? gate;
  final bool unsafe;
  final bool detailsUnavailable;
  int searches = 0;

  @override
  String get displayName => id;

  @override
  SourceCapabilities get capabilities =>
      const SourceCapabilities(search: true, chapters: true);

  @override
  Set<String> get allowedImageHosts => const {};

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    searches++;
    await gate?.future;
    return [
      Manga(
        id: '$id:$sourceMangaId',
        title: 'Shared Manga',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      ),
    ];
  }

  @override
  Future<Manga?> getMangaDetails(String sourceMangaId) async =>
      detailsUnavailable
      ? null
      : Manga(
          id: '$id:$sourceMangaId',
          title: 'Shared Manga',
          coverUrl: '',
          synopsis: unsafe
              ? 'Contains explicit sexual content.'
              : 'A harmless source synopsis.',
          status: MangaStatus.ongoing,
          chapterCount: 1,
        );

  @override
  Future<List<CanonicalChapter>> getChapters(String sourceMangaId) async =>
      const [];

  @override
  Future<CanonicalChapter?> getLatestChapter(String sourceMangaId) async =>
      null;

  @override
  Future<ChapterPages> getChapterPages(String sourceChapterId) =>
      throw UnimplementedError();
}

class _EmptyMetadata implements MetadataProvider {
  @override
  String get id => 'empty';

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async =>
      const [];

  @override
  Future<Manga?> getById(String id) async => null;
}

class _StaticMetadata implements MetadataProvider {
  const _StaticMetadata(this.id, this.values);

  @override
  final String id;
  final List<Manga> values;

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async =>
      values;

  @override
  Future<Manga?> getById(String id) async => null;
}

void main() {
  test(
    'source metadata receives stable provider and chapter mappings',
    () async {
      final provider = MangaSourceMetadataProvider(_Source('source-a', 'a-1'));

      final manga = (await provider.search('shared')).single;
      final details = await provider.getById(manga.id);

      expect(manga.metadataProviderIds, {'source-a': 'a-1'});
      expect(manga.sourceMappings, {'source-a': 'a-1'});
      expect(details?.metadataProviderIds, {'source-a': 'a-1'});
      expect(details?.sourceMappings, {'source-a': 'a-1'});
    },
  );

  test(
    'repeated equivalent autocomplete queries reuse source results',
    () async {
      final source = _Source('source-a', 'a-1');
      final provider = MangaSourceMetadataProvider(source);

      final first = await provider.search('Shared   Manga');
      final second = await provider.search(' shared manga ');

      expect(second, same(first));
      expect(source.searches, 1);
    },
  );

  test(
    'concurrent equivalent autocomplete queries share one request',
    () async {
      final gate = Completer<void>();
      final source = _Source('source-a', 'a-1', gate: gate);
      final provider = MangaSourceMetadataProvider(source);

      final first = provider.search('shared manga');
      final second = provider.search(' SHARED MANGA ');
      gate.complete();

      final values = await Future.wait([first, second]);
      expect(values[1], same(values[0]));
      expect(source.searches, 1);
    },
  );

  test(
    'equivalent source results merge without losing either mapping',
    () async {
      final empty = _EmptyMetadata();
      final repository = CatalogRepository(
        config: _config,
        metadata: empty,
        metadataProviders: [
          empty,
          MangaSourceMetadataProvider(_Source('source-a', 'a-1')),
          MangaSourceMetadataProvider(_Source('source-b', 'b-1')),
        ],
        mangaDex: MangaDexSource(),
      );

      final emissions = await repository
          .searchMetadataProgressive('shared')
          .toList();
      final result = emissions.last;

      expect(result, hasLength(1));
      expect(result.single.sourceMappings, {
        'source-a': 'a-1',
        'source-b': 'b-1',
      });
      repository.dispose();
    },
  );

  test(
    'source-only results receive a full safety pass before opening',
    () async {
      final empty = _EmptyMetadata();
      final provider = MangaSourceMetadataProvider(_Source('source-a', 'a-1'));
      final repository = CatalogRepository(
        config: _config,
        metadata: empty,
        metadataProviders: [empty, provider],
        mangaDex: MangaDexSource(),
      );
      final manga = (await provider.search('shared')).single;

      final verified = await repository.verifyForOpen(manga);

      expect(verified, isNotNull);
      expect(verified!.synopsis, 'A harmless source synopsis.');
      repository.dispose();
    },
  );

  test('unsafe source details are blocked before chapter loading', () async {
    final empty = _EmptyMetadata();
    final provider = MangaSourceMetadataProvider(
      _Source('source-a', 'a-1', unsafe: true),
    );
    final repository = CatalogRepository(
      config: _config,
      metadata: empty,
      metadataProviders: [empty, provider],
      mangaDex: MangaDexSource(),
    );
    final manga = (await provider.search('shared')).single;

    expect(await repository.verifyForOpen(manga), isNull);
    repository.dispose();
  });

  test('open verification falls back to trusted canonical metadata', () async {
    final sourceProvider = MangaSourceMetadataProvider(
      _Source('source-a', 'a-1', detailsUnavailable: true),
    );
    const trusted = Manga(
      id: 'anilist:99',
      anilistId: 99,
      metadataProviderIds: {'anilist': '99'},
      title: 'Shared Manga',
      coverUrl: '',
      synopsis: 'Trusted canonical metadata.',
      status: MangaStatus.ongoing,
      chapterCount: 10,
    );
    const canonicalProvider = _StaticMetadata('anilist', [trusted]);
    final repository = CatalogRepository(
      config: _config,
      metadata: canonicalProvider,
      metadataProviders: [canonicalProvider, sourceProvider],
      mangaDex: MangaDexSource(),
    );
    final sourceResult = (await sourceProvider.search('Shared Manga')).single;

    final verified = await repository.verifyForOpen(sourceResult);

    expect(verified, isNotNull);
    expect(verified!.anilistId, 99);
    expect(verified.sourceMappings['source-a'], 'a-1');
    repository.dispose();
  });

  test('disabled source-only cache entries are hidden from search', () {
    final empty = _EmptyMetadata();
    final repository = CatalogRepository(
      config: _config,
      metadata: empty,
      metadataProviders: [empty],
      mangaDex: MangaDexSource(),
    );
    const staleSourceOnly = Manga(
      id: 'tsuki:mangadex:a-1',
      metadataProviderIds: {'mangadex': 'a-1'},
      sourceMappings: {'mangadex': 'a-1'},
      title: 'Old source result',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.unknown,
      chapterCount: 0,
    );
    const canonicalWithChapterMapping = Manga(
      id: 'tsuki:empty:1',
      metadataProviderIds: {'empty': '1'},
      sourceMappings: {'source-a': 'a-1'},
      title: 'Canonical result',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.unknown,
      chapterCount: 0,
    );

    expect(repository.isEnabledMetadataResult(staleSourceOnly), isFalse);
    expect(
      repository.isEnabledMetadataResult(canonicalWithChapterMapping),
      isTrue,
    );
    repository.dispose();
  });

  test('search preserves an imported bookmark as the app identity', () async {
    const imported = Manga(
      id: 'tsuki:kitsu:42',
      kitsuId: '42',
      metadataProviderIds: {'kitsu': '42'},
      sourceMappings: {'mangakakalot': 'imported-work'},
      title: 'Shared Work',
      coverUrl: 'https://example.com/imported.jpg',
      synopsis: 'Imported metadata.',
      status: MangaStatus.ongoing,
      chapterCount: 10,
    );
    const liveResult = Manga(
      id: 'anilist:100',
      anilistId: 100,
      metadataProviderIds: {'anilist': '100'},
      title: 'Shared Work',
      coverUrl: 'https://example.com/live.jpg',
      synopsis: 'Live metadata.',
      status: MangaStatus.ongoing,
      chapterCount: 12,
    );
    const provider = _StaticMetadata('anilist', [liveResult]);
    final repository = CatalogRepository(
      config: _config,
      metadata: provider,
      metadataProviders: const [provider],
      mangaDex: MangaDexSource(),
    );
    repository.syncBookmarkedManga(const [imported]);

    final result = (await repository.searchMetadataOnly('Shared Work')).single;

    expect(result.id, imported.id);
    expect(result.kitsuId, '42');
    expect(result.anilistId, 100);
    expect(result.sourceMappings['mangakakalot'], 'imported-work');
    expect(repository.cached(liveResult.id)?.id, imported.id);
    repository.dispose();
  });
}
