import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/core/storage/manga_metadata_cache.dart';

const _manga = Manga(
  id: 'cache:test',
  title: 'Cache Test',
  coverUrl: '',
  synopsis: 'Safe test metadata.',
  status: MangaStatus.ongoing,
  chapterCount: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persisted search results are bounded', () async {
    final preferences = SharedPreferences.getInstance();
    final cache = MangaMetadataCache(preferences: preferences, client: Dio());

    for (var index = 0; index < 30; index++) {
      await cache.saveSearch('query $index', const [_manga]);
    }

    final prefs = await preferences;
    final searchPayloads = prefs.getKeys().where(
      (key) => key.startsWith('metadata.search.'),
    );
    expect(searchPayloads.length, 24);
    expect(prefs.getStringList('metadata.search_keys')?.length, 24);
  });

  test('malformed search payload is removed after a failed read', () async {
    final preferences = SharedPreferences.getInstance();
    final key = base64Url.encode(utf8.encode('broken'));
    final prefs = await preferences;
    await prefs.setString('metadata.search.$key', '{"items":"invalid"}');
    final cache = MangaMetadataCache(preferences: preferences, client: Dio());

    expect(await cache.loadSearch('broken'), isNull);
    expect(prefs.containsKey('metadata.search.$key'), isFalse);
  });
}
