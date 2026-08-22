import 'dart:async';

import 'package:dio/dio.dart';

Dio createHttpClient({String? baseUrl}) {
  final client = Dio(
    BaseOptions(
      baseUrl: baseUrl ?? '',
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 8),
      followRedirects: true,
      maxRedirects: 5,
      headers: const {
        // A normal Android/browser user-agent is more compatible with public
        // reader pages than a custom crawler-style UA. This does not attempt to
        // bypass challenges; protected/blocked sources still fail normally.
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9',
      },
      validateStatus: (status) =>
          status != null && status >= 200 && status < 300,
    ),
  );

  client.interceptors.add(
    InterceptorsWrapper(
      onError: (error, handler) async {
        final request = error.requestOptions;
        final status = error.response?.statusCode;
        final method = request.method.toUpperCase();
        final idempotent = method == 'GET' || method == 'HEAD';
        final retryable =
            idempotent &&
            (status == 429 ||
                status == 502 ||
                status == 503 ||
                status == 504 ||
                error.type == DioExceptionType.connectionError ||
                error.type == DioExceptionType.connectionTimeout ||
                error.type == DioExceptionType.receiveTimeout);

        if (retryable && request.extra['tsukiRetried'] != true) {
          final retryAfter =
              int.tryParse(
                error.response?.headers.value('retry-after') ?? '',
              ) ??
              1;
          await Future<void>.delayed(Duration(seconds: retryAfter.clamp(1, 3)));

          try {
            final response = await client.fetch<dynamic>(
              request.copyWith(extra: {...request.extra, 'tsukiRetried': true}),
            );
            handler.resolve(response);
            return;
          } on DioException catch (retryError) {
            error = retryError;
          }
        }

        handler.next(
          error.copyWith(
            requestOptions: error.requestOptions.copyWith(headers: const {}),
          ),
        );
      },
    ),
  );

  return client;
}
