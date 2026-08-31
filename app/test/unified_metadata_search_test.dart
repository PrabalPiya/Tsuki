import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
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

Manga _result(String id, {int? anilistId, int? malId}) => Manga(
  id: id,
  anilistId: anilistId,
  malId: malId,
  title: 'Solo Leveling',
  aliases: const ['Ore dake Level Up na Ken'],
  coverUrl: '',
  synopsis: '',
  status: MangaStatus.completed,
  chapterCount: 200,
  startYear: 2018,
  format: MangaFormat.manga,
);

class _Provider implements MetadataProvider {
  _Provider(this.id, this.results, {this.fail = false});
  @override
  final String id;
  final List<Manga> results;
  final bool fail;
  @override
  Future<Manga?> getById(String id) async => results.firstOrNull;
  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    if (fail) throw StateError('offline');
    return results;
  }
}

class _CancellableProvider implements MetadataProvider {
  final Completer<void> started = Completer<void>();

  @override
  String get id => 'cancellable';

  @override
  Future<Manga?> getById(String id) async => null;

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    started.complete();
    await cancelToken!.whenCancel;
    throw cancelToken.cancelError!;
  }
}

void main() {
  test('AniList and fallback metadata merge into one logical result', () async {
    final anilist = _Provider('anilist', [
      _result('anilist:1', anilistId: 1, malId: 99),
    ]);
    final kitsu = _Provider('kitsu', [_result('tsuki:kitsu:2', malId: 99)]);
    final repository = CatalogRepository(
      config: _config,
      metadata: anilist,
      metadataProviders: [anilist, kitsu],
      mangaDex: MangaDexSource(),
    );
    final emissions = await repository
        .searchMetadataProgressive('solo')
        .toList();
    expect(emissions, isNotEmpty);
    expect(emissions.last, hasLength(1));
    expect(emissions.last.single.anilistId, 1);
  });

  test('primary provider failure does not hide fallback results', () async {
    final anilist = _Provider('anilist', const [], fail: true);
    final kitsu = _Provider('kitsu', [_result('tsuki:kitsu:2')]);
    final repository = CatalogRepository(
      config: _config,
      metadata: anilist,
      metadataProviders: [anilist, kitsu],
      mangaDex: MangaDexSource(),
    );
    final emissions = await repository
        .searchMetadataProgressive('solo')
        .toList();
    expect(emissions.last.single.id, 'tsuki:kitsu:2');
  });

  test(
    'repeated provider failures are observable as degraded health',
    () async {
      final failing = _Provider('failing', const [], fail: true);
      final repository = CatalogRepository(
        config: _config,
        metadata: failing,
        metadataProviders: [failing],
        mangaDex: MangaDexSource(),
      );

      await repository.searchMetadataProgressive('solo').toList();
      await repository.searchMetadataProgressive('solo').toList();

      final health = repository.sourceHealth.single;
      expect(health.sourceId, 'failing');
      expect(health.consecutiveFailures, 2);
      expect(health.isDegraded, isTrue);
      repository.dispose();
    },
  );

  test('cancelled searches stop without degrading source health', () async {
    final provider = _CancellableProvider();
    final cancellation = CancelToken();
    final repository = CatalogRepository(
      config: _config,
      metadata: provider,
      metadataProviders: [provider],
      mangaDex: MangaDexSource(),
    );

    final search = repository
        .searchMetadataProgressive('solo', cancelToken: cancellation)
        .toList();
    await provider.started.future;
    cancellation.cancel('changed');
    await search;

    expect(repository.sourceHealth, isEmpty);
    repository.dispose();
  });
}
