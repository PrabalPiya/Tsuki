import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/chapter.dart';
import 'package:tsuki/core/models/manga.dart';
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
  Future<List<Manga>> search(String query) async => const [];
}

class _Store implements UserStore {
  @override
  Future<UserSnapshot> load(String uid) async => const UserSnapshot(
    bookmarks: {'anilist:home-test'},
    bookmarkedManga: {'anilist:home-test': _manga},
    progress: {},
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
  _Library() : super('test', _Store());
}

class _Catalog extends CatalogRepository {
  _Catalog()
    : super(config: _config, metadata: _Metadata(), mangaDex: MangaDexSource());

  final updates = StreamController<String>.broadcast();
  final release = Completer<void>();
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
  }) async => loaded.isEmpty ? null : loaded;

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
  void queueLibraryWarmup(Iterable<Manga> manga) {}

  @override
  void dispose() {
    updates.close();
    super.dispose();
  }
}

void main() {
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
      expect(find.text('Finding chapters…'), findsOneWidget);

      catalog.finishLoading(_manga);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Start Reading'), findsOneWidget);
      expect(find.text('Finding chapters…'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
}
