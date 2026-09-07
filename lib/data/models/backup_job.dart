import 'dart:convert';
import 'dart:math';

import '../../core/network/api_exception.dart';
import 'backup_context.dart';

enum BackupJobState {
  preparing,
  ready,
  uploading,
  reconciling,
  retry,
  paused,
  failed,
  cancelled,
  complete,
}

enum BackupSourceKind { photo, video, contacts }

String newBackupId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool isBackupId(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

String backupFolder(String value) {
  if (value.startsWith('/') ||
      value.contains(r'\') ||
      value.contains('\u0000') ||
      value.split('/').any((part) => part == '..' || part == '.')) {
    throw BackupFailure(
      'Choose a scope-relative backup folder without "." or "..".',
      code: 'destination',
      retryable: false,
    );
  }
  return value.split('/').where((part) => part.isNotEmpty).join('/');
}

String backupDestinationId(BackupContext context) => jsonEncode([
  context.settings.driveUuid ?? '',
  backupFolder(context.settings.folder),
]);

int backupSourceMask(BackupContext context) =>
    (context.settings.photos ? 1 : 0) |
    (context.settings.videos ? 2 : 0) |
    (context.settings.contacts ? 4 : 0);

String backupJoin(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';

String backupSourceFolder(BackupSourceKind kind) => switch (kind) {
  BackupSourceKind.photo => 'Photos',
  BackupSourceKind.video => 'Videos',
  BackupSourceKind.contacts => 'Contacts',
};

/// Nonsecret, immutable ownership and durable transfer state.
class BackupJob {
  const BackupJob({
    required this.jobId,
    required this.instanceId,
    required this.profileId,
    required this.userId,
    required this.destinationId,
    required this.assetId,
    required this.sourceKind,
    required this.drive,
    required this.remotePath,
    required this.filename,
    required this.createdAt,
    this.generation = 0,
    this.state = BackupJobState.preparing,
    this.localPath = '',
    this.stageDirectory,
    this.size,
    this.sha256,
    this.tusUrl,
    this.offset = 0,
    this.suffixPath,
    this.suffixOffset,
    this.attemptId,
    this.attemptCount = 0,
    this.failureCount = 0,
    this.nativeTaskId,
    this.nativeSessionId,
    this.transport,
    this.recoverable,
    this.retryAt,
    this.error,
    this.errorCode,
    this.completedAt,
    this.remoteResultPath,
  });

  final String jobId;
  final String instanceId;
  final String profileId;
  final int userId;
  final String destinationId;
  final String assetId;
  final BackupSourceKind sourceKind;
  final String drive;
  final String remotePath;
  final String filename;
  final DateTime createdAt;
  final int generation;
  final BackupJobState state;
  final String localPath;
  final String? stageDirectory;
  final int? size;
  final String? sha256;
  final String? tusUrl;
  final int offset;
  final String? suffixPath;
  final int? suffixOffset;
  final String? attemptId;
  final int attemptCount;
  final int failureCount;
  final int? nativeTaskId;
  final String? nativeSessionId;
  final String? transport;
  final bool? recoverable;
  final DateTime? retryAt;
  final String? error;
  final String? errorCode;
  final DateTime? completedAt;
  final String? remoteResultPath;

  bool get terminal =>
      state == BackupJobState.complete || state == BackupJobState.cancelled;
  bool get staged => size != null && sha256 != null && localPath.isNotEmpty;

  Map<String, Object?> toMap() => {
    'job_id': jobId,
    'instance_id': instanceId,
    'profile_id': profileId,
    'user_id': userId,
    'destination_id': destinationId,
    'asset_id': assetId,
    'source_kind': sourceKind.name,
    'drive': drive,
    'remote_path': remotePath,
    'filename': filename,
    'created_at': createdAt.toUtc().toIso8601String(),
    'generation': generation,
    'status': state.name,
    'local_path': localPath,
    'stage_directory': stageDirectory,
    'size': size,
    'sha256': sha256,
    'tus_url': tusUrl,
    'tus_offset': offset,
    'suffix_path': suffixPath,
    'suffix_offset': suffixOffset,
    'attempt_id': attemptId,
    'attempt_count': attemptCount,
    'failure_count': failureCount,
    'native_task_id': nativeTaskId,
    'native_session_id': nativeSessionId,
    'transport': transport,
    'recoverable': recoverable == null ? null : (recoverable! ? 1 : 0),
    'retry_at': retryAt?.toUtc().toIso8601String(),
    'error': error,
    'error_code': errorCode,
    'completed_at': completedAt?.toUtc().toIso8601String(),
    'remote_result_path': remoteResultPath,
  };

  factory BackupJob.fromMap(Map<String, Object?> row) => BackupJob(
    jobId: row['job_id'] as String,
    instanceId: row['instance_id'] as String,
    profileId: row['profile_id'] as String,
    userId: row['user_id'] as int,
    destinationId: row['destination_id'] as String,
    assetId: row['asset_id'] as String,
    sourceKind: BackupSourceKind.values.byName(row['source_kind'] as String),
    drive: row['drive'] as String,
    remotePath: row['remote_path'] as String,
    filename: row['filename'] as String,
    createdAt: DateTime.parse(row['created_at'] as String),
    generation: row['generation'] as int? ?? 0,
    state: BackupJobState.values.byName(row['status'] as String),
    localPath: row['local_path'] as String,
    stageDirectory: row['stage_directory'] as String?,
    size: row['size'] as int?,
    sha256: row['sha256'] as String?,
    tusUrl: row['tus_url'] as String?,
    offset: row['tus_offset'] as int? ?? 0,
    suffixPath: row['suffix_path'] as String?,
    suffixOffset: row['suffix_offset'] as int?,
    attemptId: row['attempt_id'] as String?,
    attemptCount: row['attempt_count'] as int? ?? 0,
    failureCount: row['failure_count'] as int? ?? 0,
    nativeTaskId: row['native_task_id'] as int?,
    nativeSessionId: row['native_session_id'] as String?,
    transport: row['transport'] as String?,
    recoverable: row['recoverable'] == null ? null : row['recoverable'] == 1,
    retryAt: _date(row['retry_at']),
    error: row['error'] as String?,
    errorCode: row['error_code'] as String?,
    completedAt: _date(row['completed_at']),
    remoteResultPath: row['remote_result_path'] as String?,
  );

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.parse(value as String);
}

class BackupFailure extends ApiException {
  BackupFailure(
    super.message, {
    required this.code,
    this.retryable = true,
    this.waiting = false,
    super.statusCode,
    super.isNetwork,
    super.isAuth,
  });

  final String code;
  final bool retryable;
  final bool waiting;
}

class BackupReceipt {
  const BackupReceipt({
    required this.jobId,
    required this.state,
    required this.uploadUrl,
    required this.size,
    required this.sha256,
    required this.drive,
    required this.path,
    required this.filename,
    required this.remotePath,
    this.error,
  });

  final String jobId;
  final String state;
  final String uploadUrl;
  final int size;
  final String sha256;
  final String drive;
  final String path;
  final String filename;
  final String remotePath;
  final String? error;

  factory BackupReceipt.fromJson(Map<String, dynamic> json) => BackupReceipt(
    jobId: json['jobId'] as String,
    state: json['state'] as String,
    uploadUrl: json['uploadUrl'] as String,
    size: json['size'] as int,
    sha256: json['sha256'] as String,
    drive: json['drive'] as String,
    path: json['path'] as String,
    filename: json['filename'] as String,
    remotePath: json['remotePath'] as String,
    error: json['error'] as String?,
  );

  void validate(BackupJob job) {
    if (jobId != job.jobId ||
        size != job.size ||
        sha256 != job.sha256 ||
        drive != job.drive ||
        path != job.remotePath ||
        !const {
          'uploading',
          'finalizing',
          'complete',
          'failed',
        }.contains(state) ||
        filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.contains(RegExp(r'[/\\\x00]')) ||
        remotePath != backupJoin(path, filename)) {
      throw BackupFailure(
        'The server recovery record does not match this backup job.',
        code: 'receipt_mismatch',
        retryable: false,
      );
    }
  }
}
