import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/models/reading_progress.dart';
import 'package:tsuki/core/state/app_state.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/core/storage/user_store.dart';
import 'package:tsuki/features/home/presentation/home_screen.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';

const _config = AppConfig(
  environment: AppEnvironment.development,
  useDemoData: false,
  firebaseProjectId: '',
  firebaseAppId: '',
  firebaseApiKey: '',
  firebaseMessagingSenderId: '',
  backendBaseUrl: '',
  remoteCatalogUrl: '',
);

const _manga = Manga(
  id: 'anilist:home-test',
  title: 'Home Test',
  coverUrl: '',
  synopsis: '',
  status: MangaStatus.ongoing,
  chapterCount: 12,
);

class _Metadata implements MetadataProvider {
  @override
  String get id => 'test';

  @override
  Future<Manga?> getById(String id) async => null;

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async =>
      const [];
}

class _Store implements UserStore {
  const _Store({this.progress = const {}});

  final Map<String, ReadingProgress> progress;

  @override
  Future<UserSnapshot> load(String uid) async => UserSnapshot(
    bookmarks: const {'anilist:home-test'},
    bookmarkedManga: const {'anilist:home-test': _manga},
    progress: progress,
  );

  @override
  Future<void> clearSession(String uid) async {}

  @override
  Future<void> saveBookmarks(
    String uid,
    Set<String> ids,
    Map<String, Manga> manga,
  ) async {}

  @override
  Future<void> saveProgress(String uid, value) async {}
}

class _Library extends UserLibraryController {
  _Library([_Store store = const _Store()]) : super('test', store);
}

class _Catalog extends CatalogRepository {
  _Catalog()
    : super(config: _config, metadata: _Metadata(), mangaDex: MangaDexSource());

  final updates = StreamController<String>.broadcast();
  final release = Completer<void>();
  Completer<void>? localGate;
  List<CanonicalChapter> loaded = const [];

  @override
  Stream<String> get chapterUpdates => updates.stream;

  @override
  Manga? cached(String id) => id == _manga.id ? _manga : null;

  @override
  List<CanonicalChapter>? memoryChapters(
    Manga manga, {
    bool allowAdult = false,
  }) => loaded.isEmpty ? null : loaded;

  @override
  Future<List<CanonicalChapter>?> localChapters(
    Manga manga, {
    bool allowAdult = false,
  }) async {
    await localGate?.future;
    return loaded.isEmpty ? null : loaded;
  }

  @override
  Future<void> prewarmChapters(Manga manga, {bool allowAdult = false}) async {
    await release.future;
  }

  void finishLoading(Manga manga) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    loaded = [
      CanonicalChapter(
        id: 'chapter:1',
        number: 1,
        title: 'Chapter 1',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'test',
            chapterId: '1',
            reliability: 1,
            publishedAt: epoch,
          ),
        ],
      ),
    ];
    updates.add(manga.id);
    release.complete();
  }

  @override
  void queueLibraryWarmup(Iterable<Manga> manga) {
    for (final item in manga) {
      unawaited(prewarmChapters(item));
    }
  }

  @override
  void dispose() {
    updates.close();
    super.dispose();
  }
}

void main() {
  testWidgets('Home renders bookmarks before every disk lookup finishes', (
    tester,
  ) async {
    final catalog = _Catalog();
    final localGate = Completer<void>();
    catalog.localGate = localGate;
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config),
        catalogProvider.overrideWithValue(catalog),
        userLibraryProvider.overrideWith((_) => _Library()),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(_manga.title), findsWidgets);
    expect(find.text('View Chapters'), findsOneWidget);
    expect(
      find.textContaining('Latest Chapter: 12', findRichText: true),
      findsOneWidget,
    );

    localGate.complete();
    catalog.release.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets(
    'Home reading button updates when card chapter loading finishes',
    (tester) async {
      final catalog = _Catalog();
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(_config),
          catalogProvider.overrideWithValue(catalog),
          userLibraryProvider.overrideWith((_) => _Library()),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );

      await tester.pump();
      await tester.pump();
      expect(find.text('View Chapters'), findsOneWidget);

      catalog.finishLoading(_manga);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Start Reading'), findsOneWidget);
      expect(find.text('View Chapters'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets('matching visible chapter numbers move manga to Caught Up', (
    tester,
  ) async {
    final catalog = _Catalog();
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    catalog.loaded = [
      CanonicalChapter(
        id: 'chapter:1-source-a',
        number: 1,
        title: 'Chapter 1',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'test',
            chapterId: '1',
            reliability: 1,
            publishedAt: epoch,
          ),
        ],
      ),
      CanonicalChapter(
        id: 'chapter:1-source-b',
        number: 1,
        title: 'Chapter 1',
        publishedAt: epoch,
        sourceCopies: [
          ChapterSourceCopy(
            sourceId: 'backup-test',
            chapterId: '1',
            reliability: 0.9,
            publishedAt: epoch,
          ),
        ],
      ),
    ];
    final store = _Store(
      progress: {
        _manga.id: ReadingProgress(
          mangaId: _manga.id,
          chapterId: 'chapter:1-source-b',
          pageIndex: 0,
          relativeOffset: 0,
          chapterProgress: 0.1,
          openedChapterIds: const {'chapter:1-source-b'},
          updatedAt: epoch,
        ),
      },
    );
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config),
        catalogProvider.overrideWithValue(catalog),
        userLibraryProvider.overrideWith((_) => _Library(store)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    final entries = container.read(homeEntriesProvider).value;
    expect(entries, hasLength(1));
    expect(entries!.single.caughtUp, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('a late chapter update recomputes Caught Up tab membership', (
    tester,
  ) async {
    final catalog = _Catalog();
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final store = _Store(
      progress: {
        _manga.id: ReadingProgress(
          mangaId: _manga.id,
          chapterId: 'chapter:number:1',
          pageIndex: 0,
          relativeOffset: 0,
          chapterProgress: 1,
          normalizedChapterNumber: 1,
          updatedAt: epoch,
        ),
      },
    );
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(_config),
        catalogProvider.overrideWithValue(catalog),
        userLibraryProvider.overrideWith((_) => _Library(store)),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(container.read(homeEntriesProvider).value!.single.caughtUp, isFalse);

    catalog.finishLoading(_manga);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(homeEntriesProvider).value!.single.caughtUp, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
