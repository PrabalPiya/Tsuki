import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

Future<void> main(List<String> args) async {
  final pages = _intArg(args, '--pages', fallback: 25).clamp(1, 250);
  final perPage = _intArg(args, '--per-page', fallback: 50).clamp(1, 50);
  final delayMs = _intArg(args, '--delay-ms', fallback: 2200).clamp(0, 60000);
  final maxRetries = _intArg(args, '--max-retries', fallback: 5).clamp(0, 10);
  final output = _stringArg(
    args,
    '--out',
    fallback: 'assets/catalog/catalog.json',
  );

  final client = Dio(
    BaseOptions(
      baseUrl: 'https://graphql.anilist.co',
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 18),
      headers: const {'Content-Type': 'application/json'},
    ),
  );

  final seen = <String, Map<String, Object?>>{};

  for (var page = 1; page <= pages; page++) {
    stdout.writeln('Fetching AniList manga page $page/$pages...');
    final response = await _fetchPage(
      client,
      page: page,
      perPage: perPage,
      maxRetries: maxRetries,
    );

    final body = response.data as Map;
    final media = ((body['data'] as Map?)?['Page'] as Map?)?['media'] as List?;
    if (media == null || media.isEmpty) break;

    for (final raw in media) {
      final manga = _fromAniList(Map<String, dynamic>.from(raw as Map));
      if (((manga['chapterCount'] as int?) ?? 0) <= 0) continue;
      final id = manga['id'] as String;
      seen[id] = manga;
    }

    if (page < pages && delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }

  final items = seen.values.toList(growable: false)
    ..sort((a, b) {
      final popularity = ((b['popularity'] as int?) ?? 0).compareTo(
        (a['popularity'] as int?) ?? 0,
      );
      if (popularity != 0) return popularity;
      return ((b['rating'] as num?) ?? 0).compareTo((a['rating'] as num?) ?? 0);
    });

  final file = File(output);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'version': DateTime.now().millisecondsSinceEpoch,
      'items': items,
    }),
  );

  stdout.writeln('Wrote ${items.length} manga to ${file.path}');
}

Future<Response<Object?>> _fetchPage(
  Dio client, {
  required int page,
  required int perPage,
  required int maxRetries,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await client.post<Object?>(
        '/',
        data: {
          'query': _query,
          'variables': {'page': page, 'perPage': perPage},
        },
      );
    } on DioException catch (error) {
      if (attempt >= maxRetries || !_isRetryable(error)) rethrow;

      final delay = _retryDelay(error, attempt);
      stderr.writeln(
        'AniList request failed (${error.response?.statusCode ?? error.type}); '
        'retrying page $page in ${delay.inSeconds}s '
        '(${attempt + 1}/$maxRetries)...',
      );
      await Future<void>.delayed(delay);
    }
  }
}

bool _isRetryable(DioException error) {
  final status = error.response?.statusCode;
  return status == 429 ||
      (status != null && status >= 500) ||
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.receiveTimeout ||
      error.type == DioExceptionType.sendTimeout;
}

Duration _retryDelay(DioException error, int attempt) {
  final headers = error.response?.headers;
  final retryAfter = int.tryParse(headers?.value('retry-after') ?? '');
  if (retryAfter != null) {
    return Duration(seconds: retryAfter) + const Duration(milliseconds: 250);
  }

  final resetAt = int.tryParse(headers?.value('x-ratelimit-reset') ?? '');
  if (resetAt != null) {
    final remaining = DateTime.fromMillisecondsSinceEpoch(
      resetAt * 1000,
      isUtc: true,
    ).difference(DateTime.now().toUtc());
    if (!remaining.isNegative) {
      return remaining + const Duration(milliseconds: 250);
    }
  }

  final seconds = 2 << attempt;
  return Duration(seconds: seconds.clamp(2, 60));
}

int _intArg(List<String> args, String name, {required int fallback}) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return int.tryParse(args[index + 1]) ?? fallback;
}

String _stringArg(List<String> args, String name, {required String fallback}) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return fallback;
  return args[index + 1];
}

Map<String, Object?> _fromAniList(Map<String, dynamic> json) {
  final id = (json['id'] as num).toInt();
  final title = json['title'] as Map? ?? const {};
  final cover = json['coverImage'] as Map? ?? const {};
  final trailer = json['description']?.toString() ?? '';
  final averageScore = (json['averageScore'] as num?)?.toDouble();
  final chapters = (json['chapters'] as num?)?.toInt() ?? 0;
  final titleText = _title(title);

  return {
    'id': 'anilist:$id',
    'anilistId': id,
    'malId': (json['idMal'] as num?)?.toInt(),
    'mangaDexId': null,
    'title': titleText,
    'aliases': [
      title['romaji'],
      title['english'],
      title['native'],
      ...(json['synonyms'] as List? ?? const []),
    ].whereType<String>().where((value) => value.trim().isNotEmpty).toList(),
    'coverUrl':
        cover['extraLarge']?.toString() ?? cover['large']?.toString() ?? '',
    'synopsis': _stripHtml(trailer),
    'status': _status(json['status']?.toString()),
    'rating': averageScore == null ? null : averageScore / 10.0,
    'chapterCount': chapters,
    'isAdult': json['isAdult'] == true,
    'format': _format(json['format']?.toString()),
    'countryCode': json['countryOfOrigin']?.toString(),
    'startYear': ((json['startDate'] as Map?)?['year'] as num?)?.toInt(),
    'volumeCount': (json['volumes'] as num?)?.toInt() ?? 0,
    'genres': List<String>.from(json['genres'] as List? ?? const []),
    'popularity': (json['popularity'] as num?)?.toInt(),
  };
}

String _title(Map title) {
  for (final key in const ['english', 'romaji', 'native']) {
    final value = title[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return 'Untitled';
}

String _status(String? value) => switch (value) {
  'RELEASING' => 'ongoing',
  'FINISHED' => 'completed',
  'HIATUS' => 'hiatus',
  'CANCELLED' => 'cancelled',
  'NOT_YET_RELEASED' => 'notYetReleased',
  _ => 'unknown',
};

String _format(String? value) => switch (value) {
  'MANGA' => 'manga',
  'ONE_SHOT' => 'oneShot',
  'NOVEL' => 'novel',
  _ => 'unknown',
};

String _stripHtml(String value) {
  return value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#039;', "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

const _query = r'''
query CatalogPage($page: Int!, $perPage: Int!) {
  Page(page: $page, perPage: $perPage) {
    media(type: MANGA, sort: POPULARITY_DESC, isAdult: false) {
      id idMal
      title { romaji english native }
      synonyms
      coverImage { extraLarge large }
      description(asHtml: false)
      status
      format
      chapters
      volumes
      averageScore
      popularity
      genres
      isAdult
      countryOfOrigin
      startDate { year }
    }
  }
}
''';
