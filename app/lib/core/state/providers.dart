import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/auth_controller.dart';
import '../config/app_config.dart';
import '../data/catalog_repository.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/firestore_user_store.dart';
import '../storage/user_store.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/search/data/anilist_metadata_provider.dart';
import '../../features/search/state/search_controller.dart';
import '../../features/discover/data/ranking_provider.dart';
import 'app_state.dart';

final appConfigProvider = Provider<AppConfig>(
    (ref) => throw UnimplementedError('AppConfig must be overridden'));
final authProvider = StateNotifierProvider<AuthController, AppSession>(
    (ref) => AuthController(ref.watch(appConfigProvider)));
final userStoreProvider = Provider<UserStore>((ref) =>
    ref.watch(appConfigProvider).isFirebaseConfigured
        ? FirestoreUserStore()
        : const LocalUserStore());
final userLibraryProvider =
    StateNotifierProvider<UserLibraryController, UserLibraryState>((ref) {
  final session = ref.watch(authProvider);
  return UserLibraryController(
      session.uid ?? 'signed-out', ref.watch(userStoreProvider));
});
final mangaDexProvider = Provider((ref) => MangaDexSource());
final anilistProvider = Provider((ref) => AniListMetadataProvider());
final catalogProvider = Provider((ref) => CatalogRepository(
    config: ref.watch(appConfigProvider),
    metadata: ref.watch(anilistProvider),
    mangaDex: ref.watch(mangaDexProvider)));
final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>((ref) =>
        SearchController(ref.watch(catalogProvider),
            includeAdult: () => ref.read(userLibraryProvider).adultContent));
final chapterProvider = FutureProvider.family<List<CanonicalChapter>, Manga>(
    (ref, manga) => ref.watch(catalogProvider).chapters(manga));
final rankingServiceProvider = Provider<RankingProvider>((ref) {
  final catalog = ref.watch(catalogProvider);
  return ref.watch(appConfigProvider).useDemoData
      ? DemoRankingProvider(catalog.demoRankings)
      : AniListRankingProvider(ref.watch(anilistProvider));
});
final AutoDisposeFutureProviderFamily<RankingResult, RankingPeriod>
    rankingsProvider =
    FutureProvider.autoDispose.family<RankingResult, RankingPeriod>(
        (ref, period) => ref.watch(rankingServiceProvider).rankings(period));
