import 'dart:async';

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
import '../../features/reader/data/webtoon_xyz_source.dart';
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

final mangaDexProvider = Provider<MangaDexSource>((ref) => MangaDexSource());
final comicKProvider = Provider<ComicKSource>((ref) => ComicKSource());
final mangaPillProvider = Provider<MangaPillSource>((ref) => MangaPillSource());
final weebCentralProvider =
    Provider<WeebCentralSource>((ref) => WeebCentralSource());
final webtoonXyzProvider =
    Provider<WebtoonXyzSource>((ref) => WebtoonXyzSource());
final asuraProvider = Provider<AsuraSource>((ref) => AsuraSource());
final anilistProvider =
    Provider<AniListMetadataProvider>((ref) => AniListMetadataProvider());

final catalogProvider = Provider<CatalogRepository>(
  (ref) => CatalogRepository(
    config: ref.watch(appConfigProvider),
    metadata: ref.watch(anilistProvider),
    mangaDex: ref.watch(mangaDexProvider),
    comicK: ref.watch(comicKProvider),
    mangaPill: ref.watch(mangaPillProvider),
    weebCentral: ref.watch(weebCentralProvider),
    webtoonXyz: ref.watch(webtoonXyzProvider),
    asura: ref.watch(asuraProvider),
  ),
);

final chapterSummaryUpdatesProvider = StreamProvider<String>(
  (ref) => ref.watch(catalogProvider).chapterUpdates,
);

/// Reactive per-manga chapter label.
///
/// The old global update stream only told Flutter that *something* changed.
/// Discover cards could therefore keep their initial metadata value until a
/// navigation rebuild. This provider owns the lifecycle for one manga: it
/// emits the immediate cached/metadata label, primes that manga if needed,
/// then emits again whenever that manga's source index changes.
final chapterSummaryLabelProvider =
    StreamProvider.autoDispose.family<String, Manga>((ref, manga) async* {
  final adultEnabled = ref.watch(
    userLibraryProvider.select((state) => state.adultContent),
  );
  final repository = ref.watch(catalogProvider);

  yield manga.chapterDisplayLabel;

  try {
    await repository.primeChapterSummary(
      manga,
      allowAdult: adultEnabled,
    );
  } catch (_) {
    // Keep the immediate cached/metadata value when every source is offline.
  }

  yield manga.chapterDisplayLabel;

  await for (final _ in repository.chapterUpdates
      .where((mangaId) => mangaId == manga.id)) {
    yield manga.chapterDisplayLabel;
  }
});

final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>(
  (ref) => SearchController(
    ref.watch(catalogProvider),
    includeAdult: () => ref.read(userLibraryProvider).adultContent,
  ),
);

/// Chapter details are progressive rather than one-shot.
///
/// Subscribe to repository updates *before* starting the initial fetch. The
/// earlier async* implementation subscribed only after the first yield, which
/// could miss a fast background merge and leave Details stuck on a partial
/// chapter list.
final chapterProvider =
    StreamProvider.autoDispose.family<List<CanonicalChapter>, Manga>(
  (ref, manga) {
    final adultEnabled = ref.watch(
      userLibraryProvider.select((state) => state.adultContent),
    );
    final repository = ref.watch(catalogProvider);
    final controller = StreamController<List<CanonicalChapter>>();

    Future<void> emitLocal() async {
      final updated = await repository.localChapters(
        manga,
        allowAdult: adultEnabled,
      );
      if (!controller.isClosed && updated != null) {
        controller.add(updated);
      }
    }

    final subscription = repository.chapterUpdates
        .where((mangaId) => mangaId == manga.id)
        .listen((_) => unawaited(emitLocal()));

    ref.onDispose(() {
      unawaited(subscription.cancel());
      unawaited(controller.close());
    });

    unawaited(() async {
      try {
        final initial = await repository.chapters(
          manga,
          allowAdult: adultEnabled,
        );
        if (!controller.isClosed) controller.add(initial);
      } catch (error, stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
      }
    }());

    return controller.stream;
  },
);

final rankingServiceProvider = Provider<RankingProvider>((ref) {
  final catalog = ref.watch(catalogProvider);
  final config = ref.watch(appConfigProvider);
  return config.useDemoData
      ? DemoRankingProvider(catalog.demoRankings)
      : AniListRankingProvider(ref.watch(anilistProvider));
});

final AutoDisposeFutureProviderFamily<RankingResult, RankingPeriod>
    rankingsProvider = FutureProvider.autoDispose.family<RankingResult,
        RankingPeriod>(
  (ref, period) async {
    final result = await ref.watch(rankingServiceProvider).rankings(period);
    final catalog = ref.watch(catalogProvider);

    // Prime only the first few cards. This keeps Discover fast and avoids
    // turning one ranking request into dozens of source lookups.
    for (final manga in result.items.take(3)) {
      unawaited(
        catalog.primeChapterSummary(
          manga,
          allowAdult: false,
        ),
      );
    }
    return result;
  },
);
