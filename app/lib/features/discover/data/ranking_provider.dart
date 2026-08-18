import '../../../core/models/manga.dart';
import '../../search/data/anilist_metadata_provider.dart';

enum RankingPeriod { trending, topRated, popular }

class RankingResult {
  const RankingResult({
    required this.items,
    this.unavailableReason,
    this.isPreview = false,
  });
  final List<Manga> items;
  final String? unavailableReason;
  final bool isPreview;
}

abstract interface class RankingProvider {
  Future<RankingResult> rankings(RankingPeriod period);
}

class UnavailableRankingProvider implements RankingProvider {
  const UnavailableRankingProvider();
  @override
  Future<RankingResult> rankings(
    RankingPeriod period,
  ) async => const RankingResult(
    items: [],
    unavailableReason:
        'Historical ranking data is unavailable. No ranking has been invented.',
  );
}

class DemoRankingProvider implements RankingProvider {
  const DemoRankingProvider(this.items);
  final List<Manga> items;
  @override
  Future<RankingResult> rankings(RankingPeriod period) async =>
      RankingResult(items: items, isPreview: true);
}

class AniListRankingProvider implements RankingProvider {
  const AniListRankingProvider(this.metadata);
  final AniListMetadataProvider metadata;

  @override
  Future<RankingResult> rankings(RankingPeriod period) async {
    final items = switch (period) {
      RankingPeriod.trending => await metadata.browseTrending(),
      RankingPeriod.topRated => await metadata.browseTopRated(),
      RankingPeriod.popular => await metadata.browsePopular(),
    };
    return RankingResult(items: items);
  }
}
