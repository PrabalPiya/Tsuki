import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/state/providers.dart';
import 'package:tsuki/features/manga_details/presentation/manga_details_screen.dart';
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

class _MissingMetadata implements MetadataProvider {
  int detailRequests = 0;

  @override
  String get id => 'missing';

  @override
  Future<Manga?> getById(String id) async {
    detailRequests++;
    return null;
  }

  @override
  Future<List<Manga>> search(String query, {CancelToken? cancelToken}) async =>
      const [];
}

void main() {
  testWidgets('direct Details failure can retry and return Home', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final metadata = _MissingMetadata();
    final catalog = CatalogRepository(
      config: _config,
      metadata: metadata,
      mangaDex: MangaDexSource(),
    );
    final router = GoRouter(
      initialLocation: '/manga/missing:1',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
        GoRoute(
          path: '/manga/:id',
          builder: (_, state) =>
              MangaDetailsScreen(mangaId: state.pathParameters['id']!),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(_config),
          catalogProvider.overrideWithValue(catalog),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Manga unavailable right now.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
    catalog.dispose();
  });
}
