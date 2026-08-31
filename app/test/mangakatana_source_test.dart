import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/mangakatana_source.dart';

void main() {
  test('matches a title and returns readable chapters and pages', () async {
    final source = MangaKatanaSource(client: _client(_FixtureAdapter()));
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

    expect(match, 'one-piece.49');
    expect(chapters.map((chapter) => chapter.number), [1190, 1191]);
    expect(chapters.last.publishedAt, DateTime.utc(2026, 8, 21));
    expect(pages.urls, hasLength(2));
    expect(
      pages.urls.every((url) => url.startsWith('https://i1.mangakatana.com/')),
      isTrue,
    );
  });

  test('rejects page images outside MangaKatana CDNs', () async {
    final source = MangaKatanaSource(client: _client(_FixtureAdapter()));
    final pages = await source.getChapterPages(
      Uri.encodeComponent('one-piece.49/c1191'),
    );
    expect(pages.urls, isNot(contains('https://untrusted.example/3.jpg')));
  });

  test('loads source metadata after a cold start', () async {
    final source = MangaKatanaSource(client: _client(_FixtureAdapter()));

    final details = await source.getMangaDetails('one-piece.49');

    expect(details, isNotNull);
    expect(details!.title, 'One Piece');
    expect(details.status, MangaStatus.ongoing);
    expect(details.metadataChapterCount, 2);
    expect(details.sourceMappings['mangakatana'], 'one-piece.49');
  });
}

Dio _client(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://mangakatana.com'))
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
      '/' =>
        '''
        <div class="item">
          <a href="https://mangakatana.com/manga/one-piece.49">
            <img data-src="https://mangakatana.com/imgs/cover/one.webp">
          </a>
          <h3 class="title">
            <a href="https://mangakatana.com/manga/one-piece.49">One Piece</a>
          </h3>
        </div>
        <div class="item"><h3 class="title">
          <a href="/manga/one-piece-episode-ace.13306">One Piece Episode Ace</a>
        </h3></div>
      ''',
      '/manga/one-piece.49' =>
        '''
        <main><h1>One Piece</h1></main>
        <div class="summary">A pirate searches for the greatest treasure.</div>
        <div>Status: Ongoing</div>
        <div>Genres: Action, Adventure</div>
        <div class="chapters"><table>
          <tr><td><div class="chapter">
            <a href="/manga/one-piece.49/c1191">Chapter 1191: Loki is Here</a>
          </div></td><td><div class="update_time">Aug-21-2026</div></td></tr>
          <tr><td><div class="chapter">
            <a href="/manga/one-piece.49/c1190">Chapter 1190</a>
          </div></td><td><div class="update_time">Aug-07-2026</div></td></tr>
        </table></div>
      ''',
      '/manga/one-piece.49/c1191' =>
        '''
        <script>
          var pages = [
            'https://i1.mangakatana.com/token/a/0.jpg',
            'https://i1.mangakatana.com/token/b/1.webp',
            'https://untrusted.example/3.jpg'
          ];
        </script>
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
