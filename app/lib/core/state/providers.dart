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
import '../../features/reader/data/adult_madara_source.dart';
import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/comick_source.dart';
import '../../features/reader/data/hitomi_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangapill_source.dart';
import '../../features/reader/data/omega_scans_source.dart';
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

/// True means the whole app is in adult-only mode.
/// False means the whole app is in normal-only mode.
final adultModeProvider = Provider<bool>((ref) {
  return ref.watch(userLibraryProvider.select((state) => state.adultContent));
});

final mangaDexProvider = Provider<MangaDexSource>((ref) => MangaDexSource());
final ero18xProvider = Provider<AdultMadaraSource>(
  (ref) => AdultMadaraSource(
    id: 'ero18x',
    displayName: 'Ero18x',
    baseUrl: 'https://ero18x.com',
  ),
);
final toon18Provider = Provider<AdultMadaraSource>(
  (ref) => AdultMadaraSource(
    id: 'toon18',
    displayName: 'Toon18',
    baseUrl: 'https://toon18.to',
  ),
);
final comicKProvider = Provider<ComicKSource>((ref) => ComicKSource());
final hitomiProvider = Provider<HitomiSource>((ref) => HitomiSource());
final mangaPillProvider = Provider<MangaPillSource>((ref) => MangaPillSource());
final omegaScansProvider = Provider<OmegaScansSource>(
  (ref) => OmegaScansSource(),
);
final weebCentralProvider = Provider<WeebCentralSource>(
  (ref) => WeebCentralSource(),
);
final webtoonXyzProvider = Provider<WebtoonXyzSource>(
  (ref) => WebtoonXyzSource(),
);
final asuraProvider = Provider<AsuraSource>((ref) => AsuraSource());
final anilistProvider = Provider<AniListMetadataProvider>(
  (ref) => AniListMetadataProvider(),
);

final catalogProvider = Provider<CatalogRepository>((ref) {
  return CatalogRepository(
    config: ref.watch(appConfigProvider),
    metadata: ref.watch(anilistProvider),
    mangaDex: ref.watch(mangaDexProvider),
    ero18x: ref.watch(ero18xProvider),
    toon18: ref.watch(toon18Provider),
    comicK: ref.watch(comicKProvider),
    hitomi: ref.watch(hitomiProvider),
    mangaPill: ref.watch(mangaPillProvider),
    omegaScans: ref.watch(omegaScansProvider),
    weebCentral: ref.watch(weebCentralProvider),
    webtoonXyz: ref.watch(webtoonXyzProvider),
    asura: ref.watch(asuraProvider),
  );
});

final chapterSummaryUpdatesProvider = StreamProvider<String>(
  (ref) => ref.watch(catalogProvider).chapterUpdates,
);

/// Reactive chapter label for one manga card.
///
/// It emits immediately from the warmed local summary/metadata, primes that
/// manga if needed, then emits again whenever the repository learns a newer
/// source-backed value. This prevents Discover/Search cards from staying at 0
/// until the Details route causes an unrelated rebuild.
final chapterSummaryLabelProvider = StreamProvider.autoDispose
    .family<String, Manga>((ref, manga) async* {
      final adultMode = ref.watch(adultModeProvider);
      final repository = ref.watch(catalogProvider);

      yield manga.chapterDisplayLabel;

      if (manga.isAdult == adultMode) {
        try {
          await repository.primeChapterSummary(manga, allowAdult: adultMode);
        } catch (_) {
          // Keep the immediate local/metadata value when sources are unavailable.
        }
      }

      yield manga.chapterDisplayLabel;

      await for (final _ in repository.chapterUpdates.where(
        (mangaId) => mangaId == manga.id,
      )) {
        yield manga.chapterDisplayLabel;
      }
    });

final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>((ref) {
      return SearchController(
        ref.watch(catalogProvider),
        adultOnly: ref.watch(adultModeProvider),
      );
    });

/// Progressive chapter list for Details.
///
/// The subscription is installed before the first source request so a fast
/// provider merge cannot be missed between initial load and stream listening.
final chapterProvider = StreamProvider.autoDispose
    .family<List<CanonicalChapter>, Manga>((ref, manga) {
      final adultMode = ref.watch(adultModeProvider);
      final repository = ref.watch(catalogProvider);
      final controller = StreamController<List<CanonicalChapter>>();

      Future<void> emitLocal() async {
        final updated = await repository.localChapters(
          manga,
          allowAdult: adultMode,
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
        unawaited(controller.close().then<void>((_) {}));
      });

      unawaited(() async {
        try {
          if (manga.isAdult != adultMode) {
            if (!controller.isClosed) {
              controller.add(const <CanonicalChapter>[]);
            }
            return;
          }

          final initial = await repository.chapters(
            manga,
            allowAdult: adultMode,
          );
          if (!controller.isClosed) controller.add(initial);
        } catch (error, stackTrace) {
          if (!controller.isClosed) controller.addError(error, stackTrace);
        }
      }());

      return controller.stream;
    });

final rankingServiceProvider = Provider<RankingProvider>((ref) {
  final catalog = ref.watch(catalogProvider);
  final config = ref.watch(appConfigProvider);
  final adultMode = ref.watch(adultModeProvider);

  if (config.useDemoData) {
    return DemoRankingProvider(
      catalog.demoRankings
          .where((manga) => manga.isAdult == adultMode)
          .toList(growable: false),
    );
  }

  return AniListRankingProvider(
    ref.watch(anilistProvider),
    adultOnly: adultMode,
  );
});

final rankingsProvider = FutureProvider.autoDispose
    .family<RankingResult, RankingPeriod>((ref, period) async {
      final result = await ref.watch(rankingServiceProvider).rankings(period);
      final catalog = ref.watch(catalogProvider);
      final adultMode = ref.watch(adultModeProvider);

      final filtered = result.items
          .where((manga) => manga.isAdult == adultMode)
          .toList(growable: false);

      for (final manga in filtered.take(4)) {
        unawaited(catalog.primeChapterSummary(manga, allowAdult: adultMode));
      }

      return RankingResult(
        items: filtered,
        unavailableReason: result.unavailableReason,
        isPreview: result.isPreview,
      );
    });
