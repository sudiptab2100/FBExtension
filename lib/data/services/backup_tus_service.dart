import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:tus_client/tus_client.dart';

import '../../core/config/constants.dart';
import '../models/backup_context.dart';
import '../models/backup_job.dart';

BackupFailure backupHttpFailure(int status) => BackupFailure(
  switch (status) {
    401 => 'Sign in again to resume backup.',
    403 =>
      'Backup access was denied. Check the account and destination permission.',
    404 => 'The backup destination or upload is unavailable.',
    409 =>
      'The upload changed on the server. Backup will reconcile its offset.',
    410 => 'The upload expired. Backup must recover its server record.',
    412 => 'The server does not support the required tus version.',
    413 => 'The server rejected the backup file size.',
    422 => 'The server could not verify this backup content.',
    423 => 'The backup destination is locked or unavailable.',
    429 => 'The server is busy. Backup will retry later.',
    503 => 'The server or destination drive is unavailable.',
    507 => 'The destination drive does not have enough free space.',
    _ => 'The backup server returned HTTP $status.',
  },
  code: 'http_$status',
  statusCode: status,
  isAuth: status == 401,
  retryable:
      status == 408 ||
      status == 409 ||
      status == 410 ||
      status == 423 ||
      status == 429 ||
      status >= 500,
);

/// Backup-only control requests. General file-browser uploads are unchanged.
class BackupTusService {
  BackupTusService(this.context, {http.Client? client})
    : _client = client ?? _createClient(context);

  final BackupContext context;
  final http.Client _client;
  static const requestTimeout = Duration(seconds: 25);

  static http.Client _createClient(BackupContext context) {
    final origin = Uri.parse(context.instance.baseUrl);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 30);
    if (context.instance.trustSelfSigned) {
      client.badCertificateCallback = (_, host, port) =>
          origin.scheme == 'https' &&
          host == origin.host &&
          port == origin.port;
    }
    return IOClient(client);
  }

  Uri get origin => Uri.parse(context.instance.baseUrl);

  Uri uploadUrl(String location) {
    final result = origin.resolve(location);
    final parts = result.pathSegments;
    if (result.origin != origin.origin ||
        result.userInfo.isNotEmpty ||
        result.hasFragment ||
        result.hasQuery ||
        parts.length != 3 ||
        parts[0] != 'api' ||
        parts[1] != 'upload' ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parts[2])) {
      throw BackupFailure(
        'The server returned an unsafe or redirected upload address.',
        code: 'upload_origin',
        retryable: false,
      );
    }
    return result;
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    request.followRedirects = false;
    request.maxRedirects = 0;
    try {
      return await _client.send(request).timeout(requestTimeout);
    } on HandshakeException {
      throw BackupFailure(
        'The server certificate is not trusted. Check the saved server.',
        code: 'tls',
        retryable: false,
        isNetwork: true,
      );
    } on SocketException {
      throw BackupFailure(
        'Could not reach the backup server. Keep the Mac awake and connected.',
        code: 'network',
        isNetwork: true,
      );
    } on TimeoutException {
      throw BackupFailure(
        'The backup server timed out. Check the Mac and connection.',
        code: 'timeout',
        isNetwork: true,
      );
    } on http.ClientException {
      throw BackupFailure(
        'The connection to the backup server was interrupted.',
        code: 'network',
        isNetwork: true,
      );
    }
  }

  Future<http.Response> _request(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    if (url.origin != origin.origin || url.userInfo.isNotEmpty) {
      throw StateError('A backup request must remain on its approved server.');
    }
    final request = http.Request(method, url)
      ..headers.addAll({...context.headers, ...headers});
    final response = await _send(request);
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        bytes.add(chunk);
        if (bytes.length > 1024 * 1024) {
          throw BackupFailure(
            'The backup server returned an oversized control response.',
            code: 'server_response',
            retryable: false,
          );
        }
      }
    } on TimeoutException {
      throw BackupFailure(
        'The backup server response timed out.',
        code: 'timeout',
        isNetwork: true,
      );
    } on http.ClientException {
      throw BackupFailure(
        'The backup server response was interrupted.',
        code: 'network',
        isNetwork: true,
      );
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      headers: response.headers,
    );
  }

  Map<String, dynamic> _json(http.Response response) {
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw BackupFailure(
        'The backup server returned an invalid response. Check its version.',
        code: 'server_response',
        retryable: false,
      );
    } on TypeError {
      throw BackupFailure(
        'The backup server returned an incompatible response.',
        code: 'server_response',
        retryable: false,
      );
    }
  }

  Future<bool> supportsRecovery() async {
    final response = await _request('GET', origin.resolve(Api.health));
    if (response.statusCode != 200) {
      throw backupHttpFailure(response.statusCode);
    }
    final json = _json(response);
    if (json['ok'] != true) {
      throw BackupFailure(
        'The selected server is not ready for backup.',
        code: 'server_unavailable',
      );
    }
    final capabilities = json['capabilities'];
    return capabilities is Map && capabilities['backgroundBackupTus'] == 1;
  }

  Future<void> checkDestination() async {
    final response = await _request('GET', origin.resolve(Api.drives));
    if (response.statusCode != 200) {
      throw backupHttpFailure(response.statusCode);
    }
    final drives = _json(response)['drives'];
    if (drives is! List) {
      throw BackupFailure(
        'The server did not return the backup drive list.',
        code: 'server_response',
        retryable: false,
      );
    }
    Map? selected;
    for (final drive in drives) {
      if (drive is Map && drive['uuid'] == context.settings.driveUuid) {
        selected = drive;
        break;
      }
    }
    if (selected == null || selected['registered'] == false) {
      throw BackupFailure(
        'The selected backup drive is no longer registered.',
        code: 'drive_missing',
        retryable: false,
      );
    }
    if (selected['access'] != 'granted') {
      throw BackupFailure(
        'Request or restore access to the selected backup drive.',
        code: 'drive_access',
        retryable: false,
        statusCode: 403,
      );
    }
    if (selected['online'] != true) {
      throw BackupFailure(
        'Waiting for the backup drive to be connected to the Mac.',
        code: 'drive_offline',
        waiting: true,
      );
    }
    if (selected['writable'] == false) {
      throw BackupFailure(
        'The selected backup drive is read-only.',
        code: 'drive_readonly',
        retryable: false,
      );
    }
  }

  Future<BackupReceipt?> receipt(BackupJob job) async {
    final response = await _request(
      'GET',
      origin.resolve('${Api.backupUploads}/${job.jobId}'),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw backupHttpFailure(response.statusCode);
    }
    BackupReceipt result;
    try {
      result = BackupReceipt.fromJson(_json(response));
    } on TypeError {
      throw BackupFailure(
        'The server recovery record is incomplete.',
        code: 'server_response',
        retryable: false,
      );
    }
    result.validate(job);
    uploadUrl(result.uploadUrl);
    return result;
  }

  Map<String, String> metadata(BackupJob job, {required bool recoverable}) => {
    'filename': job.filename,
    'drive': job.drive,
    'path': job.remotePath,
    if (recoverable) ...{'backupJobId': job.jobId, 'backupSha256': job.sha256!},
  };

  Map<String, String> patchHeaders(BackupJob job) => {
    ...context.headers,
    'Tus-Resumable': '1.0.0',
    'Upload-Offset': '${job.offset}',
    'Content-Type': 'application/offset+octet-stream',
    'Upload-Metadata': metadata(job, recoverable: job.recoverable == true)
        .entries
        .map((item) => '${item.key} ${base64Encode(utf8.encode(item.value))}')
        .join(','),
  };

  /// The UUID, owned source and hash are already durable before this POST.
  Future<Uri?> create(BackupJob job, {required bool recoverable}) async {
    if (!job.staged ||
        job.size! < 0 ||
        !isBackupId(job.jobId) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(job.sha256!)) {
      throw StateError('A backup source must be durable before tus creation.');
    }
    final response = await _request(
      'POST',
      origin.resolve(Api.upload),
      headers: {
        'Tus-Resumable': '1.0.0',
        'Upload-Length': '${job.size}',
        'Upload-Metadata': metadata(job, recoverable: recoverable).entries
            .map(
              (item) => '${item.key} ${base64Encode(utf8.encode(item.value))}',
            )
            .join(','),
      },
    );
    if (response.statusCode == 409 && recoverable) return null;
    if (response.statusCode != 201) {
      throw backupHttpFailure(response.statusCode);
    }
    final location = response.headers['location'];
    if (location == null || location.isEmpty) {
      throw BackupFailure(
        'The server did not return the created upload address.',
        code: 'upload_location',
      );
    }
    return uploadUrl(location);
  }

  Future<int?> head(BackupJob job, Uri url) async {
    final response = await _request(
      'HEAD',
      uploadUrl(url.toString()),
      headers: {'Tus-Resumable': '1.0.0'},
    );
    if (response.statusCode == 404 || response.statusCode == 410) return null;
    if (response.statusCode != 200 && response.statusCode != 204) {
      throw backupHttpFailure(response.statusCode);
    }
    final offset = int.tryParse(response.headers['upload-offset'] ?? '');
    final size = int.tryParse(response.headers['upload-length'] ?? '');
    if (offset == null ||
        offset < 0 ||
        offset > job.size! ||
        size != job.size) {
      throw BackupFailure(
        'The server returned an invalid tus offset or file size.',
        code: 'upload_offset',
        retryable: false,
      );
    }
    return offset;
  }

  /// Keep Android's tus_client chunk transport, with a durable resource URL
  /// and an account/lease check before every chunk instead of a memory queue.
  Future<bool> uploadForeground({
    required BackupJob job,
    required Future<void> Function() beforeTransfer,
    required Future<void> Function(int offset) onOffset,
    void Function(double percent)? onProgress,
  }) async {
    final url = uploadUrl(job.tusUrl!);
    final guarded = _GuardedTusHttpClient(
      sendRequest: _send,
      validateUrl: uploadUrl,
      beforeTransfer: beforeTransfer,
      onOffset: onOffset,
      totalBytes: job.size!,
    );
    final tus = _PersistentTusClient(
      origin.resolve(Api.upload),
      XFile(job.localPath, name: job.filename),
      client: guarded,
      store: _ExistingUploadStore(url),
      headers: {
        ...context.headers,
        'Upload-Metadata': patchHeaders(job)['Upload-Metadata']!,
      },
    );
    var completed = false;
    try {
      await tus.upload(
        onProgress: onProgress,
        onComplete: () => completed = true,
      );
    } on TimeoutException {
      throw BackupFailure(
        'The foreground upload timed out. Its server offset will be recovered.',
        code: 'timeout',
        isNetwork: true,
      );
    } on http.ClientException {
      throw BackupFailure(
        'The foreground upload connection was interrupted.',
        code: 'network',
        isNetwork: true,
      );
    }
    return completed;
  }

  void close() => _client.close();
}

class _ExistingUploadStore implements TusStore {
  const _ExistingUploadStore(this.url);
  final Uri url;
  @override
  Future<Uri?> get(String fingerprint) async => url;
  @override
  Future<void> set(String fingerprint, Uri url) async {
    throw StateError(
      'Only the backup coordinator creates durable tus resources.',
    );
  }

  @override
  Future<void> remove(String fingerprint) async {}
}

class _PersistentTusClient extends TusClient {
  _PersistentTusClient(
    super.url,
    super.file, {
    required this.client,
    required super.store,
    required super.headers,
  });
  final http.Client client;
  @override
  http.Client getHttpClient() => client;
  @override
  Future<void> create() async {
    throw StateError('The backup upload URL must already be persisted.');
  }

  @override
  void onComplete() {}
}

class _GuardedTusHttpClient extends http.BaseClient {
  _GuardedTusHttpClient({
    required this.sendRequest,
    required this.validateUrl,
    required this.beforeTransfer,
    required this.onOffset,
    required this.totalBytes,
  });

  final Future<http.StreamedResponse> Function(http.BaseRequest) sendRequest;
  final Uri Function(String) validateUrl;
  final Future<void> Function() beforeTransfer;
  final Future<void> Function(int) onOffset;
  final int totalBytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    validateUrl(request.url.toString());
    await beforeTransfer();
    final response = await sendRequest(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>().timeout(
        BackupTusService.requestTimeout,
      );
      throw backupHttpFailure(response.statusCode);
    }
    final offset = int.tryParse(response.headers['upload-offset'] ?? '');
    if (offset == null || offset < 0 || offset > totalBytes) {
      await response.stream.drain<void>();
      throw BackupFailure(
        'The server returned an invalid upload offset.',
        code: 'upload_offset',
        retryable: false,
      );
    }
    if (request.method == 'PATCH') {
      final before = int.tryParse(request.headers['Upload-Offset'] ?? '');
      final length = request.contentLength;
      if (before == null || length == null || offset != before + length) {
        await response.stream.drain<void>().timeout(
          BackupTusService.requestTimeout,
        );
        throw BackupFailure(
          'The server reported a different offset for the uploaded chunk.',
          code: 'upload_offset_conflict',
        );
      }
      await onOffset(offset);
    }
    return http.StreamedResponse(
      response.stream.timeout(BackupTusService.requestTimeout),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      reasonPhrase: response.reasonPhrase,
      request: response.request,
    );
  }
}
