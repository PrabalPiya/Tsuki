import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../config/app_config.dart';
import '../data/catalog_repository.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/firestore_user_store.dart';
import '../storage/user_store.dart';

import '../../features/discover/data/ranking_provider.dart';

import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/comick_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangapill_source.dart';
import '../../features/reader/data/weebcentral_source.dart';

import '../../features/search/data/anilist_metadata_provider.dart';
import '../../features/search/state/search_controller.dart';

import 'app_state.dart';

final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('AppConfig must be overridden'),
);

final authProvider = StateNotifierProvider<AuthController, AppSession>(
  (ref) => AuthController(ref.watch(appConfigProvider)),
);

final userStoreProvider = Provider<UserStore>((ref) {
  final config = ref.watch(appConfigProvider);

  return config.isFirebaseConfigured
      ? FirestoreUserStore()
      : const LocalUserStore();
});

final userLibraryProvider =
    StateNotifierProvider<UserLibraryController, UserLibraryState>((ref) {
      final session = ref.watch(authProvider);

      return UserLibraryController(
        session.uid ?? 'signed-out',
        ref.watch(userStoreProvider),
      );
    });

/*
 * ==========================================================
 * CHAPTER SOURCES
 * ==========================================================
 */

final mangaDexProvider = Provider<MangaDexSource>((ref) => MangaDexSource());

final comicKProvider = Provider<ComicKSource>((ref) => ComicKSource());

final mangaPillProvider = Provider<MangaPillSource>((ref) => MangaPillSource());

final weebCentralProvider = Provider<WeebCentralSource>(
  (ref) => WeebCentralSource(),
);

final asuraProvider = Provider<AsuraSource>((ref) => AsuraSource());

/*
 * ==========================================================
 * ANILIST
 * ==========================================================
 */

final anilistProvider = Provider<AniListMetadataProvider>(
  (ref) => AniListMetadataProvider(),
);

/*
 * ==========================================================
 * CATALOG
 * ==========================================================
 */

final catalogProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(
    config: ref.watch(appConfigProvider),
    metadata: ref.watch(anilistProvider),
    mangaDex: ref.watch(mangaDexProvider),
    comicK: ref.watch(comicKProvider),
    mangaPill: ref.watch(mangaPillProvider),
    weebCentral: ref.watch(weebCentralProvider),
    asura: ref.watch(asuraProvider),
  ),
);

/*
 * ==========================================================
 * SEARCH
 * ==========================================================
 */

final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>(
      (ref) => SearchController(
        ref.watch(catalogProvider),
        includeAdult: () => ref.read(userLibraryProvider).adultContent,
      ),
    );

/*
 * ==========================================================
 * CHAPTERS
 * ==========================================================
 */

final chapterProvider = FutureProvider.family<List<CanonicalChapter>, Manga>((
  ref,
  manga,
) {
  final adultEnabled = ref.watch(
    userLibraryProvider.select((state) => state.adultContent),
  );

  return ref.watch(catalogProvider).chapters(manga, allowAdult: adultEnabled);
});

/*
 * ==========================================================
 * RANKINGS
 * ==========================================================
 */

final rankingServiceProvider = Provider<RankingProvider>((ref) {
  final catalog = ref.watch(catalogProvider);

  final config = ref.watch(appConfigProvider);

  return config.useDemoData
      ? DemoRankingProvider(catalog.demoRankings)
      : AniListRankingProvider(ref.watch(anilistProvider));
});

final AutoDisposeFutureProviderFamily<RankingResult, RankingPeriod>
rankingsProvider = FutureProvider.autoDispose
    .family<RankingResult, RankingPeriod>(
      (ref, period) => ref.watch(rankingServiceProvider).rankings(period),
    );
