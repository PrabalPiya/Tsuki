import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsuki/core/network/http_client.dart';

class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.statuses);

  final List<int> statuses;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final status = statuses[calls.clamp(0, statuses.length - 1)];
    calls++;
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('non-idempotent requests are never retried', () async {
    final adapter = _StatusAdapter([503, 200]);
    final client = createHttpClient()..httpClientAdapter = adapter;

    await expectLater(
      client.post<Object?>('https://example.test/write'),
      throwsA(isA<DioException>()),
    );

    expect(adapter.calls, 1);
    client.close();
  });

  test('a transient GET failure is retried once', () async {
    final adapter = _StatusAdapter([503, 200]);
    final client = createHttpClient()..httpClientAdapter = adapter;

    final response = await client.get<Object?>('https://example.test/read');

    expect(response.statusCode, 200);
    expect(adapter.calls, 2);
    client.close();
  });
}
