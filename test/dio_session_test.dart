import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/constants.dart';
import 'package:localdrive_app/core/network/dio_client.dart';

class _Adapter implements HttpClientAdapter {
  final started = Completer<RequestOptions>();
  final response = Completer<ResponseBody>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    started.complete(options);
    return response.future;
  }

  @override
  void close({bool force = false}) {}

  void reject() => response.complete(
    ResponseBody.fromString(
      '{"error":"Session expired"}',
      401,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    ),
  );
}

void main() {
  test(
    'a late old-token 401 cannot invalidate a replacement session',
    () async {
      String? token = 'old-test-token';
      var expired = 0;
      final adapter = _Adapter();
      final dio = buildDio(
        baseUrl: 'http://backup.local:4820',
        token: () => token,
        onUnauthorized: () => expired++,
      )..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final request = dio.get<dynamic>(Api.filesList);
      final sent = await adapter.started.future;
      expect(sent.headers['Authorization'], 'Bearer old-test-token');
      token = 'replacement-test-token';
      adapter.reject();
      await expectLater(request, throwsA(isA<DioException>()));
      expect(expired, 0);
    },
  );

  test('a 401 for the current session invokes expiration handling', () async {
    var expired = 0;
    final adapter = _Adapter();
    final dio = buildDio(
      baseUrl: 'http://backup.local:4820',
      token: () => 'current-test-token',
      onUnauthorized: () => expired++,
    )..httpClientAdapter = adapter;
    addTearDown(dio.close);
    final request = dio.get<dynamic>(Api.filesList);
    await adapter.started.future;
    adapter.reject();
    await expectLater(request, throwsA(isA<DioException>()));
    expect(expired, 1);
  });

  test(
    'failed public login does not invalidate another saved account',
    () async {
      var expired = 0;
      final adapter = _Adapter();
      final dio = buildDio(
        baseUrl: 'http://backup.local:4820',
        token: () => 'alice-test-token',
        onUnauthorized: () => expired++,
      )..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final request = dio.post<dynamic>(Api.login);
      await adapter.started.future;
      adapter.reject();
      await expectLater(request, throwsA(isA<DioException>()));
      expect(expired, 0);
    },
  );
}
