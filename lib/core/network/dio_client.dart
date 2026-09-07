import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../config/constants.dart';

/// Returns the current bearer token for the active instance, or null.
typedef TokenProvider = String? Function();

/// Returns the admin view-mode cookie value ('admin'|'user'), or null when the
/// caller is a normal user (the server defaults appropriately).
typedef ViewModeProvider = String? Function();

/// Builds a [Dio] bound to one server instance, wiring the auth bearer token,
/// the `ld_view` admin-scope cookie, self-signed TLS trust, and a 401 hook.
Dio buildDio({
  required String baseUrl,
  required TokenProvider token,
  ViewModeProvider? viewMode,
  bool trustSelfSigned = false,
  void Function()? onUnauthorized,
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(minutes: 5),
      headers: const {'Accept': 'application/json'},
      // We surface non-2xx as DioException and map them via ApiException.
    ),
  );

  if (trustSelfSigned) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // LAN servers commonly use a self-signed local CA. We only reach here
        // when the user has explicitly approved this instance's certificate.
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );
  }

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final t = token();
        if (t != null && t.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $t';
        }
        final vm = viewMode?.call();
        if (vm != null && vm.isNotEmpty) {
          // The server derives an admin's scope from the ld_view cookie
          // (see LocalDrive-Master src/server/http/scope.ts).
          final existing = options.headers['Cookie'];
          options.headers['Cookie'] = existing is String && existing.isNotEmpty
              ? '$existing; ld_view=$vm'
              : 'ld_view=$vm';
        }
        handler.next(options);
      },
      onError: (e, handler) {
        final current = token();
        final rejected = e.requestOptions.headers['Authorization'];
        final path = Uri.tryParse(e.requestOptions.path)?.path;
        if (e.response?.statusCode == 401 &&
            path != Api.login &&
            path != Api.register &&
            current != null &&
            rejected == 'Bearer $current') {
          onUnauthorized?.call();
        }
        handler.next(e);
      },
    ),
  );

  return dio;
}
