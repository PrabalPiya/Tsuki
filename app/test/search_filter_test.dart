import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/config/app_config.dart';
import 'package:tsuki/core/data/catalog_repository.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';
import 'package:tsuki/features/search/data/metadata_provider.dart';
import 'package:tsuki/features/search/state/search_controller.dart';

class _BrowseMetadata implements MetadataProvider, BrowseMetadataProvider {
  MangaBrowseRequest? lastRequest;

  @override
  String get id => 'browse-test';

  @override
  Future<Manga?> getById(String id) async => null;

  @override
  Future<List<Manga>> search(
    String query, {
    required bool includeAdult,
  }) async => const <Manga>[];

  @override
  Future<List<Manga>> browse(MangaBrowseRequest request) async {
    lastRequest = request;
    return const <Manga>[
      Manga(
        id: 'demo:filtered',
        title: 'Filtered Manga',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.completed,
        chapterCount: 42,
        rating: 8.8,
        genres: ['Drama'],
      ),
    ];
  }
}

void main() {
  test('filters expose genre, status and rating sort only', () async {
    final metadata = _BrowseMetadata();
    const config = AppConfig(
      environment: AppEnvironment.development,
      useDemoData: true,
      firebaseProjectId: '',
      firebaseAppId: '',
      firebaseApiKey: '',
      firebaseMessagingSenderId: '',
      backendBaseUrl: '',
    );
    final repository = CatalogRepository(
      config: config,
      metadata: metadata,
      mangaDex: MangaDexSource(),
    );
    final controller = SearchController(repository);

    controller.updateFilters(
      const SearchFilters(
        genre: 'Drama',
        status: MangaBrowseStatus.completed,
        sort: MangaBrowseSort.rating,
      ),
    );
    await controller.applyFilters();

    final request = metadata.lastRequest;
    expect(request, isNotNull);
    expect(request!.query, isEmpty);
    expect(request.adultOnly, isFalse);
    expect(request.genres, {'Drama'});
    expect(request.status, MangaBrowseStatus.completed);
    expect(request.minimumChapters, isNull);
    expect(request.sort, MangaBrowseSort.rating);
    expect(controller.state.filters.activeCount, 3);

    controller.dispose();
  });

  test('default filters do not create an empty-query browse request', () async {
    final metadata = _BrowseMetadata();
    const config = AppConfig(
      environment: AppEnvironment.development,
      useDemoData: true,
      firebaseProjectId: '',
      firebaseAppId: '',
      firebaseApiKey: '',
      firebaseMessagingSenderId: '',
      backendBaseUrl: '',
    );
    final repository = CatalogRepository(
      config: config,
      metadata: metadata,
      mangaDex: MangaDexSource(),
    );
    final controller = SearchController(repository);

    await controller.applyFilters();

    expect(metadata.lastRequest, isNull);
    expect(controller.state.results, isEmpty);
    controller.dispose();
  });
}
