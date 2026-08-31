import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';
import 'package:tsuki/features/search/presentation/search_screen.dart';

class _Metadata implements MetadataProvider {
  @override
  String get id => 'test';
  @override
  Future<Manga?> getById(String id) async => null;
  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async {
    if (query == 'missing') return const [];
    if (query == 'ダンダダン') {
      return const [
        Manga(
          id: 'anilist:2',
          anilistId: 2,
          title: 'ダンダダン',
          coverUrl: '',
          synopsis: 'A supernatural adventure.',
          status: MangaStatus.ongoing,
          chapterCount: 1,
        ),
      ];
    }
    return const [
      Manga(
        id: 'anilist:1',
        anilistId: 1,
        title: 'Paper Moon',
        coverUrl: '',
        synopsis: 'Test synopsis.',
        status: MangaStatus.ongoing,
        chapterCount: 4,
        rating: 8.4,
      ),
      Manga(
        id: 'test:paper-moon',
        metadataProviderIds: {'test': 'paper-moon'},
        title: 'Read Paper Moon Manga Online',
        coverUrl: '',
        synopsis: 'The same test manga from a reader source.',
        status: MangaStatus.ongoing,
        chapterCount: 4,
      ),
    ];
  }
}

void main() {
  testWidgets(
    'typing shows rows and submit shows cover results without bookmark actions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const config = AppConfig(
        environment: AppEnvironment.development,
        useDemoData: true,
        firebaseProjectId: '',
        firebaseAppId: '',
        firebaseApiKey: '',
        firebaseMessagingSenderId: '',
        backendBaseUrl: '',
        remoteCatalogUrl: '',
      );
      final catalog = CatalogRepository(
        config: config,
        metadata: _Metadata(),
        mangaDex: MangaDexSource(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(config),
            catalogProvider.overrideWithValue(catalog),
          ],
          child: const MaterialApp(home: SearchScreen()),
        ),
      );
      await tester.enterText(find.byType(TextField), 'paper');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('Bookmark'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Paper Moon'), findsWidgets);
      expect(find.text('Bookmark'), findsNothing);

      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pump();
      expect(find.text('Paper Moon'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.text('No manga match this search.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ダンダダン');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.text('ダンダダン'), findsWidgets);
    },
  );
}
