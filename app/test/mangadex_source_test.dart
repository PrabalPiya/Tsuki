import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/models/manga.dart';
import 'package:tsuki/features/reader/data/mangadex_source.dart';

class _RequestLog {
  const _RequestLog(this.path, this.query);

  final String path;
  final Map<String, dynamic> query;
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final FutureOr<Map<String, dynamic>> Function(RequestOptions options) handler;
  final requests = <_RequestLog>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_RequestLog(options.path, Map.of(options.queryParameters)));
    final payload = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

Dio _dio(_FakeAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://unit.test'))..httpClientAdapter = adapter;

Map<String, dynamic> _chapter(
  String id,
  String? chapter, {
  String title = '',
  String? externalUrl,
  String publishAt = '2026-01-01T00:00:00+00:00',
}) => {
  'id': id,
  'type': 'chapter',
  'attributes': {
    'chapter': chapter,
    'title': title,
    'translatedLanguage': 'en',
    'externalUrl': externalUrl,
    'publishAt': publishAt,
    'pages': externalUrl == null ? 12 : 0,
  },
  'relationships': const [
    {
      'id': 'group-1',
      'type': 'scanlation_group',
      'attributes': {'name': 'Group One'},
    },
  ],
};

void main() {
  test('fetches every MangaDex feed page before deduping chapters', () async {
    final pages = {
      0: [_chapter('c1a', '1'), _chapter('c1b', '1')],
      2: [_chapter('c2', '2'), _chapter('c3', '3')],
    };
    final adapter = _FakeAdapter((options) {
      final offset = options.queryParameters['offset'] as int;
      return {
        'result': 'ok',
        'limit': 2,
        'offset': offset,
        'total': 4,
        'data': pages[offset] ?? const [],
      };
    });
    final source = MangaDexSource(client: _dio(adapter));

    final chapters = await source.getChapters('manga-id');

    expect(adapter.requests.first.path, '/chapter');
    expect(adapter.requests.first.query['manga'], 'manga-id');
    expect(adapter.requests.map((r) => r.query['offset']), [0, 2, 0, 2]);
    expect(adapter.requests.first.query['translatedLanguage[]'], 'en');
    expect(
      adapter.requests.first.query.containsKey('includeEmptyPages'),
      isFalse,
    );
    expect(
      adapter.requests.first.query.containsKey('includeExternalUrl'),
      isFalse,
    );
    expect(adapter.requests[2].query['includeExternalUrl'], 1);
    expect(chapters.map((c) => c.numberLabel), ['1', '2', '3']);
    expect(chapters.first.sourceCopies, hasLength(2));
  });

  test('sorts decimal chapters numerically and keeps specials', () async {
    final adapter = _FakeAdapter(
      (_) => {
        'result': 'ok',
        'limit': 500,
        'offset': 0,
        'total': 4,
        'data': [
          _chapter('c11', '11'),
          _chapter('c10', '10'),
          _chapter('c10-5', '10.5'),
          _chapter('bonus', null, title: 'Bonus'),
        ],
      },
    );
    final source = MangaDexSource(client: _dio(adapter));

    final chapters = await source.getChapters('manga-id');

    expect(chapters.map((c) => c.numberLabel), ['10', '10.5', '11', 'Bonus']);
  });

  test(
    'keeps external feed entries distinct from directly readable uploads',
    () async {
      final adapter = _FakeAdapter(
        (_) => {
          'result': 'ok',
          'limit': 500,
          'offset': 0,
          'total': 1,
          'data': [
            _chapter(
              'external-1',
              '9',
              externalUrl: 'https://publisher.example/read/9',
            ),
          ],
        },
      );
      final source = MangaDexSource(client: _dio(adapter));

      final chapters = await source.getChapters('manga-id');

      expect(chapters.single.sourceCopies.single.isDirectlyReadable, isFalse);
      expect(
        chapters.single.sourceCopies.single.externalUrl,
        'https://publisher.example/read/9',
      );
    },
  );

  test('adult matching search includes all MangaDex content ratings', () async {
    final adapter = _FakeAdapter(
      (_) => {
        'result': 'ok',
        'limit': 1,
        'offset': 0,
        'total': 1,
        'data': [
          {
            'id': 'adult-id',
            'type': 'manga',
            'attributes': {
              'title': {'en': 'Adult Match'},
              'altTitles': const [],
              'description': {'en': 'Description'},
              'status': 'ongoing',
              'contentRating': 'pornographic',
              'links': const {},
            },
            'relationships': const [],
          },
        ],
      },
    );
    final source = MangaDexSource(client: _dio(adapter));

    await source.findConservativeMatch(
      const Manga(
        id: 'anilist:1',
        title: 'Adult Match',
        aliases: ['Adult Match'],
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
        isAdult: true,
      ),
    );

    expect(adapter.requests.single.query['contentRating[]'], [
      'safe',
      'suggestive',
      'erotica',
      'pornographic',
    ]);
  });

  test(
    'conservative matching accepts exact AniList links from MangaDex',
    () async {
      final adapter = _FakeAdapter(
        (_) => {
          'result': 'ok',
          'limit': 1,
          'offset': 0,
          'total': 1,
          'data': [
            {
              'id': 'linked-id',
              'type': 'manga',
              'attributes': {
                'title': {'en': 'Close But Different'},
                'altTitles': const [],
                'description': {'en': 'Description'},
                'status': 'ongoing',
                'contentRating': 'safe',
                'links': {'al': '1234'},
              },
              'relationships': const [],
            },
          ],
        },
      );
      final source = MangaDexSource(client: _dio(adapter));

      final match = await source.findConservativeMatch(
        const Manga(
          id: 'anilist:1234',
          anilistId: 1234,
          title: 'Original AniList Title',
          aliases: [],
          coverUrl: '',
          synopsis: '',
          status: MangaStatus.ongoing,
          chapterCount: 0,
        ),
      );

      expect(match, 'linked-id');
    },
  );

  test('conservative matching tries aliases before giving up', () async {
    final adapter = _FakeAdapter((options) {
      final title = options.queryParameters['title'] as String;
      return {
        'result': 'ok',
        'limit': 1,
        'offset': 0,
        'total': title == 'Alias Title' ? 1 : 0,
        'data': title == 'Alias Title'
            ? [
                {
                  'id': 'alias-id',
                  'type': 'manga',
                  'attributes': {
                    'title': {'en': 'Alias Title'},
                    'altTitles': const [],
                    'description': {'en': 'Description'},
                    'status': 'ongoing',
                    'contentRating': 'safe',
                    'links': const {},
                  },
                  'relationships': const [],
                },
              ]
            : const [],
      };
    });
    final source = MangaDexSource(client: _dio(adapter));

    final match = await source.findConservativeMatch(
      const Manga(
        id: 'anilist:1',
        title: 'Unmatched Main Title',
        aliases: ['Alias Title'],
        coverUrl: '',
        synopsis: '',
        status: MangaStatus.ongoing,
        chapterCount: 0,
      ),
    );

    expect(match, 'alias-id');
    expect(adapter.requests.map((r) => r.query['title']), [
      'Unmatched Main Title',
      'Alias Title',
    ]);
  });
}
