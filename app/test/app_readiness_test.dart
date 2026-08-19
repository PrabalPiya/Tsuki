import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/core/auth/auth_controller.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/models/reading_progress.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/core/storage/user_store.dart';
import 'package:tsuki/features/discover/data/ranking_provider.dart';
import 'package:tsuki/features/reader/presentation/reader_screen.dart';
import 'package:tsuki/features/search/data/anilist_metadata_provider.dart'
    as anilist;

const _localConfig = AppConfig(
  environment: AppEnvironment.production,
  useDemoData: false,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
);

const _manga = Manga(
  id: 'anilist:1',
  anilistId: 1,
  malId: 2,
  title: 'Paper Moon',
  coverUrl: 'https://example.com/cover.jpg',
  synopsis: 'A test manga.',
  status: MangaStatus.ongoing,
  chapterCount: 4,
  rating: 8.4,
);

class _BrowsingMetadata extends anilist.AniListMetadataProvider {
  final requested = <RankingPeriod>[];

  @override
  Future<List<Manga>> browseTopRated({bool adultOnly = false}) async {
    requested.add(RankingPeriod.topRated);
    return const [_manga];
  }

  @override
  Future<List<Manga>> browseTrending({bool adultOnly = false}) async {
    requested.add(RankingPeriod.trending);
    return const [_manga];
  }

  @override
  Future<List<Manga>> browsePopular({bool adultOnly = false}) async {
    requested.add(RankingPeriod.popular);
    return const [_manga];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'an unconfigured production build starts a usable local profile',
    () async {
      final controller = AuthController(_localConfig);
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.status, SessionStatus.ready);
      expect(controller.state.uid, 'local-user');
      expect(controller.state.isLocalProfile, isTrue);

      await controller.signOut();
      expect(controller.state.status, SessionStatus.ready);
      controller.dispose();
    },
  );

  test('local library metadata survives restart and clears safely', () async {
    const store = LocalUserStore();
    await store.saveBookmarks('reader', {_manga.id}, {_manga.id: _manga});

    final restored = await store.load('reader');
    expect(restored.bookmarks, {_manga.id});
    expect(restored.bookmarkedManga[_manga.id]?.title, _manga.title);
    expect(restored.bookmarkedManga[_manga.id]?.malId, 2);

    await store.clearSession('reader');
    final cleared = await store.load('reader');
    expect(cleared.bookmarks, isEmpty);
    expect(cleared.bookmarkedManga, isEmpty);
  });

  test(
    'trending, top rated, and popular rankings use distinct AniList feeds',
    () async {
      final metadata = _BrowsingMetadata();
      final provider = AniListRankingProvider(metadata, adultOnly: false);

      for (final period in RankingPeriod.values) {
        final result = await provider.rankings(period);
        expect(result.items.single.title, _manga.title);
        expect(result.isPreview, isFalse);
      }

      expect(metadata.requested, [
        RankingPeriod.trending,
        RankingPeriod.topRated,
        RankingPeriod.popular,
      ]);
    },
  );

  test('legacy progress marks only its current chapter as opened', () {
    final progress = ReadingProgress.fromJson({
      'mangaId': 'manga',
      'chapterId': 'chapter-4',
      'pageIndex': 2,
      'relativeOffset': .5,
      'chapterProgress': .4,
      'updatedAt': '2026-01-01T00:00:00.000Z',
    });

    expect(progress.openedChapterIds, {'chapter-4'});
    expect(progress.toJson()['openedChapterIds'], ['chapter-4']);
  });

  testWidgets('demo reader opens a chapter and has no dead overflow action', (
    tester,
  ) async {
    const config = AppConfig(
      environment: AppEnvironment.development,
      useDemoData: true,
      firebaseProjectId: '',
      firebaseAppId: '',
      firebaseApiKey: '',
      firebaseMessagingSenderId: '',
      backendBaseUrl: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appConfigProvider.overrideWithValue(config)],
        child: const MaterialApp(
          home: ReaderScreen(mangaId: 'demo:paper-moon'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Synthetic preview page 1'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}
