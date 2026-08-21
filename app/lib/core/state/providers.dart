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
    .family<String, Manga>((ref, manga) async* {
      final repository = ref.watch(catalogProvider);

      yield manga.chapterDisplayLabel;

      if (!manga.isAdult) {
        try {
          await repository.primeChapterSummary(manga, allowAdult: false);
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
      return SearchController(ref.watch(catalogProvider));
    });

final chapterProvider = StreamProvider.autoDispose
    .family<List<CanonicalChapter>, Manga>((ref, manga) {
      final repository = ref.watch(catalogProvider);
      final controller = StreamController<List<CanonicalChapter>>();

      if (manga.isAdult) {
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
      catalog.demoRankings.where((manga) => !manga.isAdult).toList(growable: false),
    );
  }

  return AniListRankingProvider(ref.watch(anilistProvider), adultOnly: false);
});

final rankingsProvider = FutureProvider.autoDispose
    .family<RankingResult, RankingPeriod>((ref, period) async {
      final result = await ref.watch(rankingServiceProvider).rankings(period);
      final catalog = ref.watch(catalogProvider);

      final safe = result.items.where((manga) => !manga.isAdult).toList();
      final filtered = await catalog.filterReadableManga(
        safe,
        targetCount: 18,
        concurrency: 4,
      );

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
    });
