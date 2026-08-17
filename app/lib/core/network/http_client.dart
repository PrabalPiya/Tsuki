import 'dart:async';

import 'package:dio/dio.dart';

Dio createHttpClient({String? baseUrl}) {
  final client = Dio(BaseOptions(
    baseUrl: baseUrl ?? '',
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 8),
    headers: const {
      'User-Agent': 'Tsuki/1.0 (open-source; contact via repository)'
    },
    validateStatus: (status) => status != null && status >= 200 && status < 300,
  ));
  client.interceptors.add(InterceptorsWrapper(onError: (error, handler) async {
    final request = error.requestOptions;
    final status = error.response?.statusCode;
    final retryable = status == 429 ||
        status == 502 ||
        status == 503 ||
        status == 504 ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout;
    if (retryable && request.extra['tsukiRetried'] != true) {
      final retryAfter =
          int.tryParse(error.response?.headers.value('retry-after') ?? '') ?? 1;
      await Future<void>.delayed(Duration(seconds: retryAfter.clamp(1, 3)));
      try {
        final response = await client.fetch<dynamic>(
            request.copyWith(extra: {...request.extra, 'tsukiRetried': true}));
        handler.resolve(response);
        return;
      } on DioException catch (retryError) {
        error = retryError;
      }
    }
    handler.next(error.copyWith(
        requestOptions: error.requestOptions.copyWith(headers: const {})));
  }));
  return client;
}
