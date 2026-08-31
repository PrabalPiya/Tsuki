import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/discover/data/ranking_provider.dart';
import 'package:tsuki/features/discover/presentation/discover_screen.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/anilist_metadata_provider.dart';

void main() {
  test(
    'discover periods should use the correct AniList ranking types',
    () async {
      final metadata = _FakeMetadata();
      final provider = AniListRankingProvider(metadata);

      await provider.rankings(RankingPeriod.trending);
      await provider.rankings(RankingPeriod.topRated);
      await provider.rankings(RankingPeriod.popular);

      expect(metadata.calls, ['trending', 'topRated', 'popular']);
    },
  );

  test('Discover preserves an existing migrated bookmark identity', () {
    const saved = Manga(
      id: 'imported:blue',
      anilistId: 1,
      title: 'Blue Story',
      coverUrl: '',
      synopsis: 'A safe story.',
      status: MangaStatus.ongoing,
      chapterCount: 1,
    );
    const ranking = Manga(
      id: 'anilist:1',
      anilistId: 1,
      title: 'Blue Story',
      coverUrl: '',
      synopsis: 'A safe story.',
      status: MangaStatus.ongoing,
      chapterCount: 1,
    );
    const config = AppConfig(
      environment: AppEnvironment.development,
      useDemoData: false,
      firebaseProjectId: '',
      firebaseAppId: '',
      firebaseApiKey: '',
      firebaseMessagingSenderId: '',
      backendBaseUrl: '',
      remoteCatalogUrl: '',
    );
    final metadata = _FakeMetadata();
    final repository = CatalogRepository(
      config: config,
      metadata: metadata,
      mangaDex: MangaDexSource(),
    )..syncBookmarkedManga(const [saved]);

    final result = canonicalizeDiscoverItems(const [ranking], repository);

    expect(result.single.id, saved.id);
    repository.dispose();
  });
}

class _FakeMetadata extends AniListMetadataProvider {
  final calls = <String>[];

  @override
  Future<List<Manga>> browseTopRated() async {
    calls.add('topRated');
    return const [];
  }

  @override
  Future<List<Manga>> browseTrending() async {
    calls.add('trending');
    return const [];
  }

  @override
  Future<List<Manga>> browsePopularThisSeason() async {
    calls.add('season');
    return const [];
  }

  @override
  Future<List<Manga>> browsePopular() async {
    calls.add('popular');
    return const [];
  }
}
