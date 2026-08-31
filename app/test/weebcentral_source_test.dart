import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/weebcentral_source.dart';

void main() {
  test('matches a title and returns readable chapters and pages', () async {
    final source = WeebCentralSource(client: _client(_FixtureAdapter()));
    const manga = Manga(
      id: 'anilist:30013',
      title: 'One Piece',
      coverUrl: '',
      synopsis: '',
      status: MangaStatus.ongoing,
      chapterCount: 0,
    );

    final match = await source.findConservativeMatch(manga);
    final chapters = await source.getChapters(match!);
    final pages = await source.getChapterPages(
      chapters.last.sourceCopies.single.chapterId,
    );

    expect(match, '01J76XY7E9FNDZ1DBBM6PBJPFK');
    expect(chapters.map((chapter) => chapter.number), [1189, 1190]);
    expect(
      chapters.last.publishedAt,
      DateTime.utc(2026, 8, 7, 15, 10, 56, 544, 424),
    );
    expect(pages.urls, hasLength(2));
    expect(
      pages.urls.every(
        (url) => url.startsWith('https://scans-hot.planeptune.us/'),
      ),
      isTrue,
    );
  });

  test('rejects page images outside the source CDN', () async {
    final source = WeebCentralSource(client: _client(_FixtureAdapter()));
    final pages = await source.getChapterPages('01KZECDZH06AWDQEJZAAQA9C2P');
    expect(pages.urls, isNot(contains('https://untrusted.example/3.png')));
  });

  test('loads source metadata after a cold start', () async {
    final source = WeebCentralSource(client: _client(_FixtureAdapter()));

    final details = await source.getMangaDetails('01J76XY7E9FNDZ1DBBM6PBJPFK');

    expect(details, isNotNull);
    expect(details!.title, 'One Piece');
    expect(details.status, MangaStatus.ongoing);
    expect(details.sourceMappings['weebcentral'], '01J76XY7E9FNDZ1DBBM6PBJPFK');
  });
}

Dio _client(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://weebcentral.com'))
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
      '/search/simple' =>
        '''
        <a href="/series/01J76XY7E9FNDZ1DBBM6PBJPFK/One-Piece">
          <img src="https://temp.compsci88.com/cover.jpg" alt="One Piece cover">
        </a>
        <a href="/series/01J76XYB7C9TMA6MY4NSGZVEVY/One-Piece-Party">
          <img alt="One Piece Party cover">
        </a>
      ''',
      '/series/01J76XY7E9FNDZ1DBBM6PBJPFK/full-chapter-list' =>
        '''
        <a href="/chapters/01KZECDZH06AWDQEJZAAQA9C2P">
          Chapter 1190 Last Read 2026-08-07T15:10:56.544424Z
        </a>
        <a href="/chapters/01KYAKWT8Y9JFC21GGD0X3KG9C">
          Chapter 1189 Last Read 2026-07-24T17:48:43.166298Z
        </a>
      ''',
      '/series/01J76XY7E9FNDZ1DBBM6PBJPFK' =>
        '''
        <main>
          <h1>One Piece</h1>
          <img src="https://temp.compsci88.com/cover.jpg">
          <article><p>A pirate searches for the greatest treasure.</p></article>
          <div>Status: Ongoing</div>
          <div>Genres: Action, Adventure</div>
        </main>
      ''',
      '/chapters/01KZECDZH06AWDQEJZAAQA9C2P/images' =>
        '''
        <img src="https://scans-hot.planeptune.us/manga/One-Piece/1190-001.png">
        <img data-src="https://scans-hot.planeptune.us/manga/One-Piece/1190-002.png">
        <img src="https://untrusted.example/3.png">
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
