import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/manganato_source.dart';

void main() {
  test('matches a title and exposes its newest readable chapter', () async {
    final source = ManganatoSource(client: _client(_FixtureAdapter()));
    const manga = Manga(
      id: 'anilist:111025',
      title: 'MookHyang: Dark Lady',
      aliases: ['Mookhyang - Dark Lady'],
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

    expect(match, 'mookhyang-dark-lady');
    expect(chapters.map((chapter) => chapter.number), [295, 296, 297]);
    expect(latest.number, 297);
    expect(pages.urls, hasLength(2));
    expect(
      pages.urls.every((url) => url.startsWith('https://storage.waitst.com/')),
      isTrue,
    );
  });

  test('rejects a slug page whose title does not match', () async {
    final source = ManganatoSource(client: _client(_FixtureAdapter()));

    expect(await source.search('Different Manga'), isEmpty);
  });
}

Dio _client(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://www.manganato.gg'))
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
    if (options.path == '/api/manga/mookhyang-dark-lady/chapters') {
      return ResponseBody.fromString(
        jsonEncode({
          'success': true,
          'data': {
            'chapters': [
              {
                'chapter_name': 'Chapter 297',
                'chapter_slug': 'chapter-297',
                'chapter_num': 297,
                'updated_at': '2026-08-25T11:17:47.000000Z',
              },
              {
                'chapter_name': 'Chapter 296',
                'chapter_slug': 'chapter-296',
                'chapter_num': 296,
                'updated_at': '2026-08-10T11:17:47.000000Z',
              },
              {
                'chapter_name': 'Chapter 295',
                'chapter_slug': 'chapter-295',
                'chapter_num': 295,
                'updated_at': '2026-08-08T11:17:47.000000Z',
              },
            ],
          },
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }

    final body = switch (options.path) {
      '/manga/mookhyang-dark-lady' =>
        '''
        <h1>Mookhyang - Dark Lady</h1>
        <div class="info-image">
          <img alt="Mookhyang - Dark Lady" src="https://storage.waitst.com/thumb/dark-lady.webp">
        </div>
      ''',
      '/manga/mookhyang-dark-lady/chapter-297' =>
        '''
        <img src="https://storage.waitst.com/mookhyang-dark-lady/297/0.webp">
        <img data-src="https://storage.waitst.com/mookhyang-dark-lady/297/1.webp">
        <img src="https://untrusted.example/mookhyang-dark-lady/297/2.webp">
      ''',
      '/manga/different-manga' => '<h1>Unrelated Work</h1>',
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
