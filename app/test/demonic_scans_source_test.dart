import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/demonic_scans_source.dart';

void main() {
  test('matches a title and exposes its newest readable chapter', () async {
    final source = DemonicScansSource(client: _client(_FixtureAdapter()));
    const manga = Manga(
      id: 'anilist:111025',
      title: 'MookHyang: Dark Lady',
      aliases: ['MookHyang - Dark Lady'],
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
    );

    final match = await source.findConservativeMatch(manga);
    final chapters = await source.getChapters(match!);
    final latest = await source.getLatestChapter(match);
    final pages = await source.getChapterPages(
      latest!.sourceCopies.single.chapterId,
    );

    expect(Uri.decodeComponent(match), '/manga/MookHyang-%25252D-Dark-Lady');
    expect(chapters.map((chapter) => chapter.number), [295, 296, 297]);
    expect(latest.number, 297);
    expect(latest.publishedAt, DateTime(2026, 8, 25));
    expect(pages.urls, hasLength(2));
    expect(
      pages.urls.every((url) => url.startsWith('https://cdn.demoniclibs.com/')),
      isTrue,
    );
  });

  test('also provides stable, directly mapped metadata', () async {
    final source = DemonicScansSource(client: _client(_FixtureAdapter()));

    final search = await source.search('MookHyang');
    final result = search.first;
    final sourceId = result.sourceMappings['demonicscans'];
    final details = await source.getById(result.id);

    expect(sourceId, isNotNull);
    expect(result.metadataProviderIds['demonicscans'], sourceId);
    expect(details, isNotNull);
    expect(details!.title, 'MookHyang: Dark Lady');
    expect(details.status, MangaStatus.ongoing);
    expect(details.metadataChapterCount, 3);
    expect(details.sourceMappings['demonicscans'], sourceId);
  });
}

Dio _client(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://demonicscans.org'))
      ..httpClientAdapter = adapter;

class _FixtureAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = switch (options.path) {
      '/search.php' =>
        '''
        <a href="/manga/MookHyang-%25252D-Dark-Lady">
          <img src="https://readermc.org/images/thumbnails/dark-lady.webp">
          <div class="seach-right"><div>MookHyang - Dark Lady</div></div>
        </a>
        <a href="/manga/MookHyang-%25252D-The-Origin">
          <div class="seach-right"><div>MookHyang - The Origin</div></div>
        </a>
      ''',
      '/manga/MookHyang-%25252D-Dark-Lady' =>
        '''
        <meta property="og:image" content="https://readermc.org/images/dark-lady.webp">
        <main>
          <h1>MookHyang: Dark Lady</h1>
          <div class="description">A martial artist awakens in another world.</div>
          <div>Status: Ongoing</div>
        </main>
        <a href="/chaptered.php?manga=157&chapter=297" class="chplinks">
          Chapter 297 <span>2026-08-25</span>
        </a>
        <a href="chaptered.php?manga=157&chapter=296" class="chplinks">
          Chapter 296 <span>2026-08-10</span>
        </a>
        <a href="https://demonicscans.org/chaptered.php?manga=157&chapter=295" class="chplinks">
          Chapter 295 <span>2026-08-08</span>
        </a>
      ''',
      '/chaptered.php' =>
        '''
        <img class="imgholder" src="/img/free_ads.jpg">
        <img class="imgholder" src="https://cdn.demoniclibs.com/MookHyang/297/0.jpg">
        <img class="imgholder" src="https://cdn.demoniclibs.com/MookHyang/297/1.jpg">
        <img class="imgholder" src="https://untrusted.example/MookHyang/297/2.jpg">
      ''',
      _ => '',
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }
}
