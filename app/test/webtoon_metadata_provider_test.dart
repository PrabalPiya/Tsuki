import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/search/data/webtoon_metadata_provider.dart';

void main() {
  test('searches WEBTOON and loads full metadata by stable title id', () async {
    final provider = WebtoonMetadataProvider(
      client: _client(_FixtureAdapter()),
    );

    final results = await provider.search('omniscient reader');
    final result = results.single;

    expect(result.id, 'tsuki:webtoon:2154');
    expect(result.metadataProviderIds, {'webtoon': '2154'});
    expect(result.title, 'Omniscient Reader');
    expect(result.authors, ['singNsong', 'UMI']);
    expect(result.popularity, 592000000);

    final details = await provider.getById('webtoon:2154');
    expect(details, isNotNull);
    expect(details!.title, 'Omniscient Reader');
    expect(details.synopsis, contains('favorite web novel'));
    expect(details.genres, ['Action']);
    expect(details.status, MangaStatus.hiatus);
    expect(details.metadataChapterCount, 309);
  });

  test('filters unsafe titles and unsafe full descriptions', () async {
    final provider = WebtoonMetadataProvider(
      client: _client(_FixtureAdapter()),
    );

    final results = await provider.search('reader');

    expect(results.map((manga) => manga.title), ['Omniscient Reader']);
  });
}

Dio _client(HttpClientAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://www.webtoons.com'))
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
      '/en/search' =>
        '''
        <ul class="webtoon_list">
          <li><a class="link" data-title-no="2154"
            href="https://www.webtoons.com/en/action/omniscient-reader/list?title_no=2154">
            <img src="https://webtoon-phinf.pstatic.net/cover.jpg">
            <strong class="title">Omniscient Reader</strong>
            <div class="author">singNsong / UMI</div>
            <div class="view_count">592M Views</div>
          </a></li>
          <li><a class="link" data-title-no="9999"
            href="/en/canvas/unsafe/list?title_no=9999">
            <strong class="title">Explicit Adult Story</strong>
          </a></li>
        </ul>
        ''',
      '/en/action/omniscient-reader/list' =>
        '''
        <div class="detail_header">
          <span class="thmb"><img src="https://webtoon-phinf.pstatic.net/detail.jpg"></span>
          <h2 class="genre">Action</h2>
          <h1 class="subj">Omniscient Reader</h1>
          <div class="author_area">singNsong, UMI, Sleepy-C author info</div>
        </div>
        <div class="aside detail">
          <p class="day_info">Omniscient Reader will return!</p>
          <p class="summary">Dokja reads his favorite web novel before it becomes reality.</p>
        </div>
        <li data-episode-no="309"></li>
        <li data-episode-no="308"></li>
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
