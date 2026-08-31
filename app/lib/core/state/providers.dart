import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_controller.dart';
import '../config/app_config.dart';
import '../data/catalog_repository.dart';
import '../models/chapter.dart';
import '../models/manga.dart';
import '../storage/firestore_user_store.dart';
import '../storage/canonical_alias_index.dart';
import '../storage/chapter_index_cache.dart';
import '../storage/manga_metadata_cache.dart';
import '../storage/user_store.dart';

import '../../features/discover/data/ranking_provider.dart';
import '../../features/migration/data/migration_service.dart';
import '../../features/migration/data/import_session_repository.dart';
import '../../features/reader/data/asura_source.dart';
import '../../features/reader/data/demonic_scans_source.dart';
import '../../features/reader/data/mangadex_source.dart';
import '../../features/reader/data/mangakakalot_source.dart';
import '../../features/reader/data/mangakatana_source.dart';
import '../../features/reader/data/weebcentral_source.dart';
import '../../features/search/data/anilist_metadata_provider.dart';
import '../../features/search/data/kitsu_metadata_provider.dart';
import '../../features/search/data/manga_source_metadata_provider.dart';
import '../../features/search/data/webtoon_metadata_provider.dart';
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
  return config.isFirebaseConfigured ? FirestoreUserStore() : LocalUserStore();
});

final mangaMetadataCacheProvider = Provider<MangaMetadataCache>((ref) {
  final cache = MangaMetadataCache(
    remoteCatalogUrl: ref.watch(appConfigProvider).remoteCatalogUrl,
  );
  unawaited(
    cache.importBundledCatalog().then((_) => cache.refreshRemoteCatalog()),
  );
  unawaited(cache.warmSearchIndex());
  ref.onDispose(cache.dispose);
  return cache;
});

final canonicalAliasIndexProvider = Provider<CanonicalAliasIndex>(
  (ref) => CanonicalAliasIndex(preferences: SharedPreferences.getInstance()),
);

final userLibraryProvider =
    StateNotifierProvider<UserLibraryController, UserLibraryState>((ref) {
      final uid = ref.watch(authProvider.select((session) => session.uid));
      final controller = UserLibraryController(
        uid ?? 'signed-out',
        ref.watch(userStoreProvider),
      );

      final subscription = controller.stream
          .map((next) => next.bookmarkedManga)
          .distinct(identical)
          .listen((bookmarkedManga) {
            ref
                .read(catalogProvider)
                .syncBookmarkedManga(bookmarkedManga.values);
            if (bookmarkedManga.isEmpty) return;
            unawaited(
              ref
                  .read(mangaMetadataCacheProvider)
                  .mergeManga(bookmarkedManga.values.toList(growable: false))
                  .catchError((_) {}),
            );
          });
      ref.onDispose(() {
        unawaited(subscription.cancel());
      });

      return controller;
    });

final mangaDexProvider = Provider<MangaDexSource>((ref) => MangaDexSource());
final demonicScansProvider = Provider<DemonicScansSource>(
  (ref) => DemonicScansSource(),
);
final mangakakalotProvider = Provider<MangakakalotSource>(
  (ref) => MangakakalotSource(),
);
final mangaKatanaProvider = Provider<MangaKatanaSource>(
  (ref) => MangaKatanaSource(),
);
final asuraProvider = Provider<AsuraSource>((ref) => AsuraSource());
final weebCentralProvider = Provider<WeebCentralSource>(
  (ref) => WeebCentralSource(),
);
final anilistProvider = Provider<AniListMetadataProvider>(
  (ref) => AniListMetadataProvider(),
);
final kitsuProvider = Provider<KitsuMetadataProvider>(
  (ref) => KitsuMetadataProvider(),
);
final webtoonProvider = Provider<WebtoonMetadataProvider>(
  (ref) => WebtoonMetadataProvider(),
);

final catalogProvider = Provider<CatalogRepository>((ref) {
  final repository = CatalogRepository(
    config: ref.watch(appConfigProvider),
    metadata: ref.watch(anilistProvider),
    metadataProviders: [
      ref.watch(anilistProvider),
      ref.watch(kitsuProvider),
      ref.watch(webtoonProvider),
      MangaSourceMetadataProvider(ref.watch(asuraProvider)),
      MangaSourceMetadataProvider(ref.watch(mangakakalotProvider)),
      MangaSourceMetadataProvider(ref.watch(demonicScansProvider)),
    ],
    mangaDex: ref.watch(mangaDexProvider),
    demonicScans: ref.watch(demonicScansProvider),
    mangakakalot: ref.watch(mangakakalotProvider),
    mangaKatana: ref.watch(mangaKatanaProvider),
    asura: ref.watch(asuraProvider),
    weebCentral: ref.watch(weebCentralProvider),
    chapterIndexCache: ChapterIndexCache(
      preferences: SharedPreferences.getInstance(),
    ),
  );
  ref.onDispose(repository.dispose);
  return repository;
});

final chapterSummaryUpdatesProvider = StreamProvider<String>(
  (ref) => ref.watch(catalogProvider).chapterUpdates,
);

final sourceHealthProvider = StreamProvider<List<SourceHealthSnapshot>>((
  ref,
) async* {
  final catalog = ref.watch(catalogProvider);
  yield catalog.sourceHealth;
  await for (final _ in catalog.sourceHealthUpdates) {
    yield catalog.sourceHealth;
  }
});

final chapterSummaryLabelProvider = StreamProvider.autoDispose
    .family<String?, Manga>((ref, manga) async* {
      final repository = ref.watch(catalogProvider);

      yield manga.catalogChapterDisplayLabel;
      repository.queueChapterSummaryWarmup(manga);

      await for (final _ in repository.chapterUpdates.where(
        (mangaId) => mangaId == manga.id,
      )) {
        yield manga.catalogChapterDisplayLabel;
      }
    });

final searchProvider =
    StateNotifierProvider.autoDispose<SearchController, SearchState>((ref) {
      return SearchController(
        ref.watch(catalogProvider),
        ref.watch(mangaMetadataCacheProvider),
        ref.watch(canonicalAliasIndexProvider),
      );
    });

final migrationServiceProvider = Provider<MigrationService>(
  (ref) => MigrationService(
    catalog: ref.watch(catalogProvider),
    cache: ref.watch(mangaMetadataCacheProvider),
    aliases: ref.watch(canonicalAliasIndexProvider),
    sessions: ImportSessionRepository(
      preferences: SharedPreferences.getInstance(),
    ),
  ),
);

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
          final initial = await repository.chapters(manga, allowAdult: false);
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

final rankingsProvider = StreamProvider.autoDispose
    .family<RankingResult, RankingPeriod>((ref, period) async* {
      ref.keepAlive();

      final catalog = ref.watch(catalogProvider);
      final cache = ref.watch(mangaMetadataCacheProvider);
      final cached = await cache.loadRanking(period);
      var hasFallback = false;

      if (cached != null && cached.items.isNotEmpty) {
        hasFallback = true;
        for (final manga in cached.items) {
          catalog.remember(manga);
        }
        yield cached;
      }

      if (!hasFallback) {
        final preview = await cache.loadCatalogPreview();
        hasFallback = preview.isNotEmpty;
        for (final manga in preview) {
          catalog.remember(manga);
        }
        if (preview.isNotEmpty) {
          yield RankingResult(
            items: preview,
            unavailableReason: null,
            isPreview: true,
          );
        }
      }

      final result = await _loadRanking(ref, period);
      if (result.items.isNotEmpty) {
        await cache.saveRanking(period, result);
        yield result;
      } else if (!hasFallback) {
        yield result;
      }
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

  final filtered = result.items
      .where(catalog.isFriendly)
      .take(18)
      .toList(growable: false);

  for (final manga in filtered) {
    catalog.remember(manga);
  }

  return RankingResult(
    items: filtered,
    unavailableReason: result.unavailableReason,
    isPreview: result.isPreview,
  );
}
