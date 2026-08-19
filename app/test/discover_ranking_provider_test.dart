import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/discover/data/ranking_provider.dart';
import 'package:tsuki/features/search/data/anilist_metadata_provider.dart';

void main() {
  test(
    'discover periods should use the correct AniList ranking types',
    () async {
      final metadata = _FakeMetadata();
      final provider = AniListRankingProvider(metadata, adultOnly: false);

      await provider.rankings(RankingPeriod.trending);
      await provider.rankings(RankingPeriod.topRated);
      await provider.rankings(RankingPeriod.popular);

      expect(metadata.calls, ['trending', 'topRated', 'popular']);
    },
  );
}

class _FakeMetadata extends AniListMetadataProvider {
  final calls = <String>[];

  @override
  Future<List<Manga>> browseTopRated({bool adultOnly = false}) async {
    calls.add('topRated');
    return const [];
  }

  @override
  Future<List<Manga>> browseTrending({bool adultOnly = false}) async {
    calls.add('trending');
    return const [];
  }

  @override
  Future<List<Manga>> browsePopularThisSeason({bool adultOnly = false}) async {
    calls.add('season');
    return const [];
  }

  @override
  Future<List<Manga>> browsePopular({bool adultOnly = false}) async {
    calls.add('popular');
    return const [];
  }
}
