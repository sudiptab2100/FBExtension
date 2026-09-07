import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:localdrive_app/core/storage/local_db.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/services/background_upload_service.dart';
import 'package:localdrive_app/data/services/backup_tus_service.dart';
import 'package:localdrive_app/data/services/media_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

class MemoryBackupDb extends Fake implements LocalDb {
  final jobs = <String, BackupJob>{};
  final profiles = <String, Map<String, Object?>>{};
  final ledger = <String, BackupJob>{};
  final claims = <String, String>{};
  final leases = <String, ({String owner, DateTime until})>{};
  final events = <String>{};
  final attempts = <String>{};
  final trace = <String>[];
  bool failCommit = false;

  String _profileKey(String profile, String destination) =>
      jsonEncode([profile, destination]);
  String _assetKey(String profile, String destination, String asset) =>
      jsonEncode([profile, destination, asset]);
  String _contextKey(BackupContext context) =>
      _profileKey(context.profileId, backupDestinationId(context));
  bool _owned(String profile, String owner) =>
      leases[LocalDb.profileLock(profile)]?.owner == owner;

  @override
  Future<bool> acquireBackupLease(
    String key,
    String owner,
    DateTime now,
  ) async {
    final old = leases[key];
    if (old != null && old.owner != owner && old.until.isAfter(now)) {
      return false;
    }
    leases[key] = (owner: owner, until: now.add(LocalDb.leaseDuration));
    return true;
  }

  @override
  Future<bool> renewBackupLease(String key, String owner, DateTime now) async {
    final old = leases[key];
    if (old == null || old.owner != owner || !old.until.isAfter(now)) {
      return false;
    }
    leases[key] = (owner: owner, until: now.add(LocalDb.leaseDuration));
    return true;
  }

  @override
  Future<void> releaseBackupLease(String key, String owner) async {
    if (leases[key]?.owner == owner) leases.remove(key);
    claims.removeWhere((_, value) => value == owner);
  }

  @override
  Future<bool> hasBackupLease(String profileId, DateTime now) async =>
      leases[LocalDb.profileLock(profileId)]?.until.isAfter(now) == true;

  @override
  Future<void> ensureBackupProfile(BackupContext context) async {
    profiles.putIfAbsent(
      _contextKey(context),
      () => {
        'profile_id': context.profileId,
        'destination_id': backupDestinationId(context),
        'generation': context.generation,
        'source_mask': backupSourceMask(context),
        'scan_index': 0,
        'contacts_scanned': 0,
        'needs_scan': 1,
        'scan_complete': 0,
        'skipped': 0,
      },
    );
  }

  @override
  Future<Map<String, Object?>> backupProfile(BackupContext context) async =>
      Map.of(profiles[_contextKey(context)] ?? {});
  @override
  Future<bool> updateBackupProfile(
    BackupContext context,
    Map<String, Object?> values, {
    String? leaseOwner,
    DateTime? now,
  }) async {
    await ensureBackupProfile(context);
    if (leaseOwner != null && !_owned(context.profileId, leaseOwner)) {
      return false;
    }
    profiles[_contextKey(context)]!.addAll(values);
    return true;
  }

  @override
  Future<Map<String, Object?>> beginBackupPass(
    BackupContext context,
    DateTime now,
    String leaseOwner,
  ) async {
    await ensureBackupProfile(context);
    final state = profiles[_contextKey(context)]!;
    if (state['scan_id'] == null ||
        state['needs_scan'] == 0 ||
        state['generation'] != context.generation ||
        state['source_mask'] != backupSourceMask(context)) {
      state.addAll({
        'scan_id': newBackupId(),
        'scan_index': 0,
        'contacts_scanned': 0,
        'needs_scan': 1,
        'scan_complete': 0,
        'scan_error': null,
        'scan_started_at': now.toIso8601String(),
        'skipped': 0,
      });
    }
    state.addAll({
      'last_attempt_at': now.toIso8601String(),
      'generation': context.generation,
      'source_mask': backupSourceMask(context),
      'waiting_reason': null,
      'error': null,
      'next_retry_at': null,
    });
    return Map.of(state);
  }

  @override
  Future<bool> isOwnedAssetBackedUp({
    required String profileId,
    required String destinationId,
    required String assetId,
  }) async => ledger.containsKey(_assetKey(profileId, destinationId, assetId));
  @override
  Future<int> ownedBackedUpCount(
    String profileId,
    String destinationId,
  ) async => ledger.values
      .where(
        (job) =>
            job.profileId == profileId && job.destinationId == destinationId,
      )
      .length;
  @override
  Future<BackupJob?> backupJob(String jobId) async => jobs[jobId];
  @override
  Future<BackupJob?> backupJobForAsset(
    String profileId,
    String destinationId,
    String assetId,
  ) async {
    for (final job in jobs.values) {
      if (job.profileId == profileId &&
          job.destinationId == destinationId &&
          job.assetId == assetId &&
          job.state != BackupJobState.cancelled) {
        return job;
      }
    }
    return null;
  }

  @override
  Future<List<BackupJob>> backupJobs({
    String? profileId,
    String? destinationId,
    bool includeTerminal = false,
    int? limit,
  }) async {
    final result = jobs.values.where(
      (job) =>
          (profileId == null || job.profileId == profileId) &&
          (destinationId == null || job.destinationId == destinationId) &&
          (includeTerminal || !job.terminal),
    );
    return (limit == null ? result : result.take(limit)).toList();
  }

  @override
  Future<BackupJob?> createBackupJob(
    BackupJob job,
    String leaseOwner,
    DateTime now,
  ) async {
    if (!_owned(job.profileId, leaseOwner) ||
        await backupJobForAsset(
              job.profileId,
              job.destinationId,
              job.assetId,
            ) !=
            null ||
        await isOwnedAssetBackedUp(
          profileId: job.profileId,
          destinationId: job.destinationId,
          assetId: job.assetId,
        )) {
      return null;
    }
    jobs[job.jobId] = job;
    claims[job.jobId] = leaseOwner;
    trace.add('job:${job.jobId}');
    return job;
  }

  @override
  Future<bool> claimBackupJob(
    BackupJob job,
    String leaseOwner,
    DateTime now,
  ) async {
    if (!_owned(job.profileId, leaseOwner) || jobs[job.jobId]!.terminal) {
      return false;
    }
    claims[job.jobId] = leaseOwner;
    return true;
  }

  @override
  Future<bool> updateBackupJob(
    String jobId,
    Map<String, Object?> values, {
    String? leaseOwner,
    String? attemptId,
    BackupJobState? expectedState,
  }) async {
    final job = jobs[jobId];
    if (job == null ||
        job.terminal ||
        (leaseOwner != null &&
            (claims[jobId] != leaseOwner ||
                !_owned(job.profileId, leaseOwner))) ||
        (attemptId != null && job.attemptId != attemptId) ||
        (expectedState != null && job.state != expectedState)) {
      return false;
    }
    jobs[jobId] = BackupJob.fromMap({...job.toMap(), ...values});
    return true;
  }

  @override
  Future<bool> startBackupAttempt({
    required BackupJob job,
    required String attemptId,
    required String transport,
    required String leaseOwner,
    required int generation,
    required DateTime now,
  }) async {
    if (!_owned(job.profileId, leaseOwner)) return false;
    final changed = await updateBackupJob(job.jobId, {
      'attempt_id': attemptId,
      'attempt_count': job.attemptCount + 1,
      'generation': generation,
      'status': BackupJobState.uploading.name,
      'transport': transport,
      'retry_at': null,
      'error': null,
      'error_code': null,
    }, leaseOwner: leaseOwner);
    if (changed) {
      attempts.add(attemptId);
      trace.add('attempt:$attemptId');
    }
    return changed;
  }

  @override
  Future<void> recordNativeEnqueue({
    required String jobId,
    required String attemptId,
    required int taskId,
    required String sessionId,
  }) async {
    await updateBackupJob(jobId, {
      'native_task_id': taskId,
      'native_session_id': sessionId,
    }, attemptId: attemptId);
  }

  @override
  Future<void> recordNativeCompletion({
    required String eventId,
    required String jobId,
    required String attemptId,
    required int? statusCode,
    required int? offset,
    required bool cancelled,
    required String? errorCode,
    required DateTime completedAt,
    BackupReceipt? receipt,
    BackupFailure? failure,
    DateTime? retryAt,
  }) async {
    if (failCommit) throw StateError('Synthetic database failure');
    if (events.contains(eventId)) return;
    final job = jobs[jobId];
    if (job != null && !job.terminal && job.attemptId == attemptId) {
      if (receipt?.state == 'complete') {
        await completeBackupJob(
          jobId,
          receipt!.remotePath,
          completedAt,
          receipt: receipt,
        );
      } else if (job.state != BackupJobState.paused) {
        await updateBackupJob(jobId, {
          'status': failure == null
              ? BackupJobState.reconciling.name
              : (failure.retryable
                    ? BackupJobState.retry.name
                    : BackupJobState.failed.name),
          'error': failure?.message,
          'error_code': failure?.code,
          'retry_at': retryAt?.toIso8601String(),
          if (failure != null) 'failure_count': job.failureCount + 1,
        }, attemptId: attemptId);
      }
    }
    events.add(eventId);
    trace.add('commit:$eventId');
  }

  @override
  Future<void> completeBackupJob(
    String jobId,
    String remotePath,
    DateTime now, {
    BackupReceipt? receipt,
  }) async {
    final job = jobs[jobId];
    if (job == null || job.terminal) return;
    if (job.recoverable == true && receipt == null) {
      throw StateError('Missing receipt');
    }
    receipt?.validate(job);
    ledger.putIfAbsent(
      _assetKey(job.profileId, job.destinationId, job.assetId),
      () => job,
    );
    await updateBackupJob(jobId, {
      'status': BackupJobState.complete.name,
      'tus_offset': job.size,
      'completed_at': now.toIso8601String(),
      'remote_result_path': remotePath,
      'error': null,
      'error_code': null,
      'retry_at': null,
    });
    _finish(job.profileId, job.destinationId, now);
  }

  void _finish(String profile, String destination, DateTime now) {
    final state = profiles[_profileKey(profile, destination)];
    final sources = state?['source_mask'] as int? ?? 7;
    if (jobs.values.any(
      (job) =>
          job.profileId == profile &&
          job.destinationId == destination &&
          (sources & (1 << job.sourceKind.index)) != 0 &&
          !job.terminal,
    )) {
      return;
    }
    if (state != null &&
        state['scan_complete'] == 1 &&
        state['scan_error'] == null &&
        state['scan_id'] != state['success_scan_id']) {
      state.addAll({
        'last_success_at': now.toIso8601String(),
        'success_scan_id': state['scan_id'],
        'error': null,
        'waiting_reason': null,
        'next_retry_at': null,
      });
    }
  }

  @override
  Future<void> finishReconciledPass(
    BackupContext context,
    DateTime now,
  ) async => _finish(context.profileId, backupDestinationId(context), now);
  @override
  Future<List<BackupJob>> stopBackupProfile(
    String profileId, {
    required bool discard,
    String? leaseOwner,
    DateTime? now,
  }) async {
    final result = await backupJobs(profileId: profileId);
    leases.remove(LocalDb.profileLock(profileId));
    if (leaseOwner != null) {
      leases[LocalDb.profileLock(profileId)] = (
        owner: leaseOwner,
        until: (now ?? DateTime.now()).add(LocalDb.leaseDuration),
      );
    }
    for (final job in result) {
      await updateBackupJob(job.jobId, {
        'status': discard
            ? BackupJobState.cancelled.name
            : BackupJobState.paused.name,
        'retry_at': null,
      });
      claims.remove(job.jobId);
    }
    for (final state in profiles.values) {
      if (state['profile_id'] == profileId) {
        state.addAll({
          'scan_complete': 0,
          'needs_scan': 0,
          'waiting_reason': 'Backup paused.',
        });
      }
    }
    return result;
  }

  @override
  Future<int> ownedStagingBytes() async => jobs.values
      .where((job) => job.stageDirectory != null)
      .fold<int>(
        0,
        (total, job) =>
            total +
            (job.size ?? 0) +
            (job.suffixPath == null
                ? 0
                : (job.size ?? 0) - (job.suffixOffset ?? 0)),
      );
  @override
  Future<int> stagedBackupJobCount() async => jobs.values
      .where((job) => job.stageDirectory != null && job.localPath.isNotEmpty)
      .length;
  @override
  Future<List<BackupJob>> backupCleanupCandidates({int limit = 20}) async =>
      jobs.values
          .where((job) => job.terminal && job.stageDirectory != null)
          .take(limit)
          .toList();
  @override
  Future<void> markBackupStagingCleaned(String jobId) async {
    final job = jobs[jobId]!;
    jobs[jobId] = BackupJob.fromMap({
      ...job.toMap(),
      'stage_directory': null,
      'local_path': '',
      'suffix_path': null,
    });
  }
}

class FakeBackupMedia extends MediaService {
  FakeBackupMedia(this.input, {int count = 1})
    : gallery = List.generate(
        count,
        (i) => AssetEntity(id: 'asset-$i', typeInt: 1, width: 10, height: 10),
      );
  final File input;
  final List<AssetEntity> gallery;
  bool galleryAllowed = true;
  bool contactsAllowed = true;
  int exports = 0;
  int contactsExports = 0;
  int requests = 0;
  int pageCalls = 0;
  Future<void> Function()? beforeFile;
  BackupFailure? sourceFailure;
  @override
  Future<bool> hasGalleryAccess({
    bool photos = true,
    bool videos = true,
  }) async => galleryAllowed;
  @override
  Future<bool> hasContactsAccess() async => contactsAllowed;
  @override
  Future<bool> requestGalleryAccess() async {
    requests++;
    return galleryAllowed;
  }

  @override
  Future<bool> requestContactsAccess() async {
    requests++;
    return contactsAllowed;
  }

  @override
  Future<List<AssetEntity>> backupAssets({
    required bool photos,
    required bool videos,
    required int start,
    int count = 40,
  }) async {
    pageCalls++;
    return start >= gallery.length
        ? []
        : gallery.sublist(start, math.min(start + count, gallery.length));
  }

  @override
  Future<AssetEntity?> backupAsset(String id) async =>
      gallery.where((asset) => asset.id == id).firstOrNull;
  @override
  Future<File> backupFile(AssetEntity asset) async {
    exports++;
    await beforeFile?.call();
    if (sourceFailure != null) throw sourceFailure!;
    return input;
  }

  @override
  Future<String> backupAssetName(AssetEntity asset, File file) async =>
      '${asset.id}.jpg';
  @override
  Future<int> exportBackupContacts(
    Directory directory, {
    required Future<void> Function() checkpoint,
    int? maximumBytes,
  }) async {
    contactsExports++;
    await checkpoint();
    await File(p.join(directory.path, 'contacts.export')).writeAsString(
      'BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Synthetic Contact\r\nEND:VCARD\r\n',
    );
    return 1;
  }
}

class FakeBackupNative extends BackgroundUploadService {
  FakeBackupNative(this.db, {this.supported = true});
  final MemoryBackupDb db;
  final bool supported;
  final tasks = <NativeUploadTask>[];
  final completions = <NativeUploadCompletion>[];
  final enqueues = <Map<String, Object?>>[];
  final cancellations = <String>[];
  bool failAck = false;
  bool failEnqueue = false;
  Future<void> Function()? beforeCancel;
  int calls = 0;
  @override
  bool get isSupported => supported;
  void check() {
    calls++;
    if (!supported) throw StateError('Unsupported iOS API called');
  }

  @override
  Future<List<NativeUploadTask>> pending() async {
    check();
    return List.of(tasks);
  }

  @override
  Future<List<NativeUploadCompletion>> readCompletions() async {
    check();
    return List.of(completions);
  }

  @override
  Future<void> ackCompletions(List<String> eventIds) async {
    check();
    if (failAck) {
      throw PlatformException(
        code: 'ack_failed',
        message: 'Synthetic ACK failure',
      );
    }
    for (final eventId in eventIds) {
      if (!db.events.contains(eventId)) {
        throw StateError('ACK before database commit');
      }
      db.trace.add('ack:$eventId');
    }
    completions.removeWhere((event) => eventIds.contains(event.eventId));
  }

  @override
  Future<void> cancel(List<String> jobIds) async {
    check();
    await beforeCancel?.call();
    cancellations.addAll(jobIds);
    tasks.removeWhere((task) => jobIds.contains(task.jobId));
  }

  @override
  Future<NativeUploadTask> enqueue({
    required String jobId,
    required String attemptId,
    required Uri url,
    required String localPath,
    required int offset,
    required int totalBytes,
    required Map<String, String> headers,
    required bool wifiOnly,
    required bool trustSelfSigned,
    required String trustedOrigin,
  }) async {
    check();
    if (!db.attempts.contains(attemptId)) {
      throw StateError('Enqueue before attempt commit');
    }
    if (failEnqueue) throw PlatformException(code: 'native_unavailable');
    enqueues.add({
      'jobId': jobId,
      'attemptId': attemptId,
      'url': url,
      'localPath': localPath,
      'offset': offset,
      'totalBytes': totalBytes,
      'headers': headers,
      'body': await File(localPath).readAsBytes(),
    });
    db.trace.add('enqueue:$attemptId');
    final task = NativeUploadTask(
      taskId: enqueues.length,
      sessionId: 'stable',
      jobId: jobId,
      attemptId: attemptId,
      offset: offset,
      totalBytes: totalBytes,
    );
    tasks.add(task);
    return task;
  }

  void finish(
    BackupJob job, {
    int status = 204,
    bool cancelled = false,
    int? offset,
  }) {
    tasks.removeWhere((task) => task.jobId == job.jobId);
    completions.add(
      NativeUploadCompletion(
        eventId: newBackupId(),
        jobId: job.jobId,
        attemptId: job.attemptId!,
        totalBytes: job.size!,
        cancelled: cancelled,
        completedAt: DateTime.now().toUtc(),
        statusCode: status,
        uploadOffset: offset ?? job.size,
      ),
    );
  }
}

class FakeBackupServer {
  bool recoverable = true;
  int creates = 0;
  int foregroundUploads = 0;
  final jobs = <String, BackupJob>{};
  final offsets = <String, int>{};
  final completed = <String>{};
  final states = <String, String>{};
  BackupFailure? destinationFailure;
  BackupFailure? createFailure;
  BackupFailure? receiptFailure;
  Future<void> Function()? afterCreate;
  bool foregroundCompletes = true;

  BackupTusService service(BackupContext context) => _FakeTus(context, this);
  BackupReceipt receiptFor(BackupJob job) => BackupReceipt(
    jobId: job.jobId,
    state: completed.contains(job.jobId)
        ? 'complete'
        : (states[job.jobId] ?? 'uploading'),
    uploadUrl: '/api/upload/${job.jobId}',
    size: job.size!,
    sha256: job.sha256!,
    drive: job.drive,
    path: job.remotePath,
    filename: job.filename,
    remotePath: backupJoin(job.remotePath, job.filename),
  );
}

class _FakeTus extends BackupTusService {
  _FakeTus(super.context, this.server)
    : super(client: MockClient((_) async => http.Response('', 500)));
  final FakeBackupServer server;
  @override
  Future<bool> supportsRecovery() async => server.recoverable;
  @override
  Future<void> checkDestination() async {
    if (server.destinationFailure != null) throw server.destinationFailure!;
  }

  @override
  Future<BackupReceipt?> receipt(BackupJob job) async {
    if (server.receiptFailure != null) throw server.receiptFailure!;
    return server.jobs.containsKey(job.jobId) ? server.receiptFor(job) : null;
  }

  @override
  Future<Uri?> create(BackupJob job, {required bool recoverable}) async {
    if (!job.staged || !await File(job.localPath).exists()) {
      throw StateError('POST before durable source/hash');
    }
    server.creates++;
    server.jobs[job.jobId] = job;
    server.offsets[job.jobId] = 0;
    await server.afterCreate?.call();
    if (server.createFailure != null) throw server.createFailure!;
    return origin.resolve('/api/upload/${job.jobId}');
  }

  @override
  Future<int?> head(BackupJob job, Uri url) async => server.offsets[job.jobId];
  @override
  Future<bool> uploadForeground({
    required BackupJob job,
    required Future<void> Function() beforeTransfer,
    required Future<void> Function(int offset) onOffset,
    void Function(double percent)? onProgress,
  }) async {
    await beforeTransfer();
    server.foregroundUploads++;
    if (server.foregroundCompletes) {
      server.completed.add(job.jobId);
      server.offsets[job.jobId] = job.size!;
      await onOffset(job.size!);
      onProgress?.call(100);
    }
    return server.foregroundCompletes;
  }
}
