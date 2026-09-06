import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:tus_client/tus_client.dart';

import '../../core/config/constants.dart';
import '../../state/api_providers.dart';
import '../../state/connection_controller.dart';

/// A [TusClient] that optionally trusts a server's self-signed certificate.
///
/// tus_client uses `package:http` (not Dio), so it bypasses our Dio TLS trust.
/// When the active instance was approved with a self-signed cert we swap in an
/// [IOClient] backed by a permissive [HttpClient].
class _TusClient extends TusClient {
  _TusClient(
    super.url,
    super.file, {
    super.store,
    super.headers,
    super.metadata,
    required this.trustSelfSigned,
  });

  final bool trustSelfSigned;

  @override
  http.Client getHttpClient() {
    if (!trustSelfSigned) return super.getHttpClient();
    final inner = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(inner);
  }
}

/// A running upload the UI can observe and cancel.
class UploadHandle {
  UploadHandle(this._client);
  final TusClient _client;

  /// Pause (and effectively cancel) the in-flight upload.
  void pause() => _client.pause();
}

/// Resumable file uploads to `/api/upload` (tus protocol).
///
/// Metadata mirrors what the server expects: `filename`, `drive`, and the
/// destination `path` (scope-relative). Auth is carried via [headers] (bearer
/// token + admin `ld_view` cookie) since tus runs outside Dio.
class UploadService {
  UploadService({
    required this.baseUrl,
    required this.headers,
    required this.trustSelfSigned,
    TusStore? store,
  }) : _store = store ?? TusMemoryStore();

  final String baseUrl;
  final Map<String, String> headers;
  final bool trustSelfSigned;
  final TusStore _store;

  /// Upload [file] into [drive] at [destPath]. Reports 0–100 progress.
  Future<void> upload({
    required XFile file,
    required String drive,
    required String destPath,
    void Function(double percent)? onProgress,
    void Function()? onComplete,
    void Function(UploadHandle handle)? onStart,
  }) async {
    final client = _TusClient(
      Uri.parse('$baseUrl${Api.upload}'),
      file,
      store: _store,
      trustSelfSigned: trustSelfSigned,
      headers: {...headers},
      metadata: {
        'filename': file.name,
        'drive': drive,
        'path': destPath,
      },
    );
    onStart?.call(UploadHandle(client));
    await client.upload(onProgress: onProgress, onComplete: onComplete);
  }
}

/// Upload service bound to the active instance's URL, TLS trust, and auth.
final uploadServiceProvider = Provider<UploadService>((ref) {
  final active = ref.watch(activeInstanceProvider);
  final headers = ref.watch(authHeadersProvider);
  return UploadService(
    baseUrl: active?.baseUrl ?? '',
    headers: headers,
    trustSelfSigned: active?.trustSelfSigned ?? false,
  );
});
