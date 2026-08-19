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
        id: 'anilist:1',
        title: 'Filtered Manga',
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.completed,
        chapterCount: 20,
        rating: 8.8,
      ),
    ];
  }
}

void main() {
  test('filters browse manga without a title query', () async {
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
    final controller = SearchController(repository, adultOnly: false);

    controller.updateFilters(
      const SearchFilters(
        minimumRating: 8,
        minimumChapters: 25,
        sort: MangaBrowseSort.rating,
      ),
    );
    await controller.applyFilters();

    expect(metadata.lastRequest, isNotNull);
    expect(metadata.lastRequest!.query, isEmpty);
    expect(metadata.lastRequest!.minimumRating, 8);
    expect(metadata.lastRequest!.minimumChapters, 25);
    expect(metadata.lastRequest!.sort, MangaBrowseSort.rating);
    expect(controller.state.results.single.title, 'Filtered Manga');

    controller.dispose();
  });
}
