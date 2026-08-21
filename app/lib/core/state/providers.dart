import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../config/app_config.dart';
import '../data/catalog_repository.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/firestore_user_store.dart';
import '../storage/manga_metadata_cache.dart';
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

final mangaMetadataCacheProvider = Provider<MangaMetadataCache>((ref) {
  final cache = MangaMetadataCache(
    remoteCatalogUrl: ref.watch(appConfigProvider).remoteCatalogUrl,
  );
  unawaited(
    cache.importBundledCatalog().then((_) => cache.refreshRemoteCatalog()),
  );
  return cache;
});

final userLibraryProvider =
    StateNotifierProvider<UserLibraryController, UserLibraryState>((ref) {
      final session = ref.watch(authProvider);
      final controller = UserLibraryController(
        session.uid ?? 'signed-out',
        ref.watch(userStoreProvider),
      );

      final subscription = controller.stream.listen((next) {
        if (next.bookmarkedManga.isEmpty) return;
        unawaited(
          ref
              .read(mangaMetadataCacheProvider)
              .mergeManga(next.bookmarkedManga.values.toList(growable: false)),
        );
      });
      ref.onDispose(() {
        unawaited(subscription.cancel());
      });

      return controller;
    });

final mangaDexProvider = Provider<MangaDexSource>((ref) => MangaDexSource());
final comicKProvider = Provider<ComicKSource>((ref) => ComicKSource());
final mangaPillProvider = Provider<MangaPillSource>((ref) => MangaPillSource());
final weebCentralProvider = Provider<WeebCentralSource>(
  (ref) => WeebCentralSource(),
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
    comicK: ref.watch(comicKProvider),
    mangaPill: ref.watch(mangaPillProvider),
    weebCentral: ref.watch(weebCentralProvider),
    asura: ref.watch(asuraProvider),
  );
});

final chapterSummaryUpdatesProvider = StreamProvider<String>(
  (ref) => ref.watch(catalogProvider).chapterUpdates,
);

final chapterSummaryLabelProvider = StreamProvider.autoDispose
    .family<String?, Manga>((ref, manga) async* {
      final repository = ref.watch(catalogProvider);

      yield manga.verifiedChapterDisplayLabel;

      if (repository.isFriendly(manga)) {
        try {
          await repository.primeChapterSummary(manga, allowAdult: false);
        } catch (_) {
          // Keep the immediate local/metadata value when sources are unavailable.
        }
      }

      yield manga.verifiedChapterDisplayLabel;

      await for (final _ in repository.chapterUpdates.where(
        (mangaId) => mangaId == manga.id,
      )) {
        yield manga.verifiedChapterDisplayLabel;
      }
    });

final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>((ref) {
      return SearchController(
        ref.watch(catalogProvider),
        ref.watch(mangaMetadataCacheProvider),
      );
    });

final chapterProvider = StreamProvider.autoDispose
    .family<List<CanonicalChapter>, Manga>((ref, manga) {
      final repository = ref.watch(catalogProvider);
      final controller = StreamController<List<CanonicalChapter>>();

      if (!repository.isFriendly(manga)) {
        controller.add(const <CanonicalChapter>[]);
        unawaited(controller.close().then<void>((_) {}));
        return controller.stream;
      }

      final memory = repository.memoryChapters(manga, allowAdult: false);
      if (memory != null && memory.isNotEmpty) {
        controller.add(memory);
      }

      Future<void> emitLocal() async {
        final updated = await repository.localChapters(
          manga,
          allowAdult: false,
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
          final initial = await repository.chapters(
            manga,
            allowAdult: false,
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

  if (config.useDemoData) {
    return DemoRankingProvider(
      catalog.demoRankings.where(catalog.isFriendly).toList(growable: false),
    );
  }

  return AniListRankingProvider(ref.watch(anilistProvider));
});

final rankingsProvider = FutureProvider.autoDispose
    .family<RankingResult, RankingPeriod>((ref, period) async {
      ref.keepAlive();

      final catalog = ref.watch(catalogProvider);
      final cache = ref.watch(mangaMetadataCacheProvider);
      final cached = await cache.loadRanking(period);

      if (cached != null && cached.items.isNotEmpty) {
        for (final manga in cached.items) {
          catalog.remember(manga);
        }

        unawaited(() async {
          final fresh = await _loadRanking(ref, period);
          if (fresh.items.isNotEmpty) {
            await cache.saveRanking(period, fresh);
          }
        }());

        return cached;
      }

      final preview = await cache.loadCatalogPreview();
      if (preview.isNotEmpty) {
        for (final manga in preview) {
          catalog.remember(manga);
        }

        unawaited(() async {
          final fresh = await _loadRanking(ref, period);
          if (fresh.items.isNotEmpty) {
            await cache.saveRanking(period, fresh);
          }
        }());

        return RankingResult(
          items: preview,
          unavailableReason: null,
          isPreview: true,
        );
      }

      final result = await _loadRanking(ref, period);
      if (result.items.isNotEmpty) {
        await cache.saveRanking(period, result);
      }
      return result;
    });

Future<RankingResult> _loadRanking(Ref ref, RankingPeriod period) async {
  final catalog = ref.read(catalogProvider);
  final RankingResult result;

  try {
    result = await ref.read(rankingServiceProvider).rankings(period);
  } catch (_) {
    return const RankingResult(
      items: [],
      unavailableReason:
          'Live rankings are unavailable right now. Try again later.',
    );
  }

  final filtered = await catalog.filterReadableManga(
    result.items,
    targetCount: 18,
    concurrency: 6,
  );

  for (final manga in filtered) {
    catalog.remember(manga);
  }

  for (final manga in filtered.take(2)) {
    unawaited(catalog.prewarmChapters(manga, allowAdult: false));
  }
  for (final manga in filtered.skip(2).take(4)) {
    unawaited(catalog.primeChapterSummary(manga, allowAdult: false));
  }

  return RankingResult(
    items: filtered,
    unavailableReason: result.unavailableReason,
    isPreview: result.isPreview,
  );
}
