import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

import '../../core/storage/backup_keys.dart';
import '../../core/storage/local_db.dart';
import '../../core/storage/prefs.dart';
import '../models/backup_context.dart';
import '../models/backup_job.dart';
import '../models/backup_snapshot.dart';
import 'background_session.dart';
import 'background_upload_service.dart';
import 'backup_engine.dart';
import 'backup_errors.dart';
import 'backup_policy.dart';
import 'backup_staging.dart';
import 'backup_tus_service.dart';
import 'media_service.dart';

typedef BackupBlockedReason = Future<String?> Function(
  BackupContext context, {
  bool manual,
});

class _Pass {
  _Pass({
    required this.context,
    required this.manual,
    required this.owner,
    required this.deadline,
    required this.onProgress,
  });
  final BackupContext context;
  final bool manual;
  final String owner;
  final DateTime deadline;
  final BackupProgress? onProgress;
  final Set<String> visited = {};
  final Set<String> preparedJobs = {};
  int prepared = 0;
  int transfers = 0;
  int uploaded = 0;
  int skipped = 0;
  int failed = 0;
  DateTime? lastCheckpoint;
  String? current;
  String? waiting;
  String? error;

  void report([String? name]) {
    current = name;
    onProgress?.call(uploaded, skipped, failed, name);
  }
}

/// One durable queue for UI, WorkManager, Android tus and iOS URLSession.
class BackupCoordinator {
  BackupCoordinator({
    required LocalDb db,
    MediaService media = const MediaService(),
    BackgroundUploadService? backgroundUploads,
  }) : this.testing(db: db, media: media, backgroundUploads: backgroundUploads);

  @visibleForTesting
  BackupCoordinator.testing({
    required this.db,
    this.media = const MediaService(),
    BackgroundUploadService? backgroundUploads,
    BackupStaging? staging,
    BackupTusService Function(BackupContext)? tusFactory,
    Future<bool> Function(BackupContext)? isActive,
    BackupBlockedReason? blockedReason,
    Future<BackupContext?> Function(BackupJob)? receiptContext,
    DateTime Function()? now,
  }) : backgroundUploads = backgroundUploads ?? const BackgroundUploadService(),
       _staging = staging ?? BackupStaging(),
       _tusFactory = tusFactory ?? BackupTusService.new,
       _isActive = isActive ?? isBackupContextActive,
       _blockedReason = blockedReason ?? backupBlockedReason,
       _receiptContext = receiptContext ?? _loadReceiptContext,
       _now = now ?? _utcNow;

  final LocalDb db;
  final MediaService media;
  final BackgroundUploadService backgroundUploads;
  final BackupStaging _staging;
  final BackupTusService Function(BackupContext) _tusFactory;
  final Future<bool> Function(BackupContext) _isActive;
  final BackupBlockedReason _blockedReason;
  final Future<BackupContext?> Function(BackupJob) _receiptContext;
  final DateTime Function() _now;

  static DateTime _utcNow() => DateTime.now().toUtc();
  static const legacyReason =
      'Update the LocalDrive server for recoverable background backup. '
      'This server supports only foreground "Back up now" uploads.';
  static const _scanLimit = 400;
  static const _pageSize = 40;

  static Future<BackupContext?> _loadReceiptContext(BackupJob job) async {
    final prefs = await Prefs.create();
    final account = await loadBackgroundAccount(
      prefs: prefs,
      instanceId: job.instanceId,
    );
    if (account == null || account.userId != job.userId) return null;
    return BackupContext(
      instance: account.instance,
      userId: account.userId,
      username: account.username,
      token: account.token,
      generation: account.generation,
      settings: prefs.readBackupSettings(job.instanceId, job.userId),
    );
  }

  Future<void> _check(
    _Pass pass, {
    bool policy = true,
    bool throttle = false,
  }) async {
    final now = _now();
    if (throttle &&
        pass.lastCheckpoint != null &&
        now.difference(pass.lastCheckpoint!) < const Duration(seconds: 1)) {
      return;
    }
    if (!await _isActive(pass.context)) {
      throw BackupFailure(
        'Paused because the backup account or settings changed.',
        code: 'context_changed',
        waiting: true,
        retryable: false,
      );
    }
    if (!await db.renewBackupLease(
      LocalDb.profileLock(pass.context.profileId),
      pass.owner,
      now,
    )) {
      throw BackupFailure(
        'Backup is being handled by another execution window.',
        code: 'lease_lost',
        waiting: true,
        retryable: false,
      );
    }
    if (policy) {
      final reason = await _blockedReason(pass.context, manual: pass.manual);
      if (reason != null) {
        throw BackupFailure(reason, code: 'policy', waiting: true);
      }
    }
    pass.lastCheckpoint = now;
  }

  Future<void> _writeProfile(_Pass pass, Map<String, Object?> values) async {
    await db.updateBackupProfile(
      pass.context,
      values,
      leaseOwner: pass.owner,
      now: _now(),
    );
  }

  Future<BackupResult> runPass({
    required BackupContext context,
    bool manual = false,
    BackupProgress? onProgress,
  }) async {
    await db.ensureBackupProfile(context);
    await reconcileCompletions();
    final blocked = await _blockedReason(context, manual: manual);
    if (blocked != null) {
      await db.updateBackupProfile(context, {'waiting_reason': blocked});
      final state = await snapshot(context);
      return BackupResult(queued: state.pending, waitingReason: blocked);
    }
    final persisted = await db.backupProfile(context);
    final retry = _date(persisted['next_retry_at']);
    if (!manual &&
        persisted['generation'] == context.generation &&
        retry != null &&
        retry.isAfter(_now())) {
      final state = await snapshot(context);
      return BackupResult(
        queued: state.pending,
        error: state.error,
        waitingReason: state.waitingReason ?? 'Waiting before retrying backup.',
      );
    }
    final owner = newBackupId();
    final key = LocalDb.profileLock(context.profileId);
    if (!await db.acquireBackupLease(key, owner, _now())) {
      return const BackupResult(
        waitingReason: 'Backup is already running in another execution window.',
      );
    }
    final pass = _Pass(
      context: context,
      manual: manual,
      owner: owner,
      deadline: _now().add(Duration(seconds: manual ? 180 : 90)),
      onProgress: onProgress,
    );
    BackupTusService? tus;
    try {
      await _check(pass);
      final state = await db.beginBackupPass(context, _now(), owner);
      pass.skipped = state['skipped'] as int? ?? 0;
      await _checkPermissions(context);
      tus = _tusFactory(context);
      final recoverable = await tus.supportsRecovery();
      await _check(pass);
      await tus.checkDestination();
      if (!recoverable && !manual) {
        throw BackupFailure(
          legacyReason,
          code: 'legacy_server',
          retryable: false,
          waiting: true,
        );
      }

      await _resumeJobs(pass, tus, recoverable);
      await _check(pass);
      if (context.settings.contacts) {
        await _scanContacts(pass, tus, recoverable);
      } else {
        await _writeProfile(pass, {'contacts_scanned': 1});
      }
      if (context.settings.photos || context.settings.videos) {
        await _scanGallery(pass, tus, recoverable);
      } else {
        await _finishScan(pass);
      }
      await _check(pass, policy: false);
      await db.finishReconciledPass(context, _now());
    } catch (error) {
      final failure = _failure(error);
      if (failure.waiting) {
        pass.waiting = failure.message;
      } else {
        pass.error = failure.message;
        pass.failed++;
      }
      final retryAt = failure.retryable && failure.code != 'policy'
          ? _now().add(
              failure.code == 'staging_budget'
                  ? const Duration(minutes: 2)
                  : const Duration(minutes: 5),
            )
          : null;
      await _writeProfile(pass, {
        'waiting_reason': pass.waiting,
        'error': pass.error,
        'next_retry_at': retryAt?.toIso8601String(),
        if (!failure.retryable ||
            failure.code.startsWith('permission') ||
            failure.code == 'legacy_server') ...{
          'scan_complete': 0,
          'needs_scan': 0,
          'scan_error': failure.message,
        },
      });
    } finally {
      tus?.close();
      await db.releaseBackupLease(key, owner);
    }
    pass.report();
    final finalState = await snapshot(context);
    return BackupResult(
      uploaded: pass.uploaded,
      skipped: pass.skipped,
      failed: math.max(pass.failed, finalState.failed),
      queued: finalState.pending,
      error: pass.error ?? finalState.error,
      waitingReason: pass.waiting ?? finalState.waitingReason,
    );
  }

  Future<void> _checkPermissions(BackupContext context) async {
    final settings = context.settings;
    if ((settings.photos || settings.videos) &&
        !await media.hasGalleryAccess(
          photos: settings.photos,
          videos: settings.videos,
        )) {
      throw BackupFailure(
        'Allow photo-library access in Settings before backing up photos or videos.',
        code: 'permission_photos',
        waiting: true,
        retryable: false,
      );
    }
    if (settings.contacts && !await media.hasContactsAccess()) {
      throw BackupFailure(
        'Allow contacts access in Settings before backing up contacts.',
        code: 'permission_contacts',
        waiting: true,
        retryable: false,
      );
    }
  }

  bool _sourceEnabled(BackupJob job, BackupContext context) =>
      switch (job.sourceKind) {
        BackupSourceKind.photo => context.settings.photos,
        BackupSourceKind.video => context.settings.videos,
        BackupSourceKind.contacts => context.settings.contacts,
      };

  Future<void> _resumeJobs(
    _Pass pass,
    BackupTusService tus,
    bool recoverable,
  ) async {
    final jobs =
        (await db.backupJobs(
              profileId: pass.context.profileId,
              destinationId: backupDestinationId(pass.context),
            ))
            .where((job) => _sourceEnabled(job, pass.context))
            .take(BackupStaging.maxPreparedItems);
    final pending = await _pending();
    for (final job in jobs) {
      if (!_sourceEnabled(job, pass.context) ||
          pending.any((task) => task.jobId == job.jobId)) {
        continue;
      }
      if (!pass.manual &&
          job.generation == pass.context.generation &&
          job.retryAt?.isAfter(_now()) == true) {
        continue;
      }
      if (job.state == BackupJobState.failed &&
          !pass.manual &&
          job.generation == pass.context.generation) {
        continue;
      }
      if (_outOfTime(pass) ||
          pass.transfers >= BackupStaging.maxPreparedItems) {
        return;
      }
      await _processJob(pass, tus, recoverable, job);
    }
  }

  Future<void> _scanGallery(
    _Pass pass,
    BackupTusService tus,
    bool recoverable,
  ) async {
    final context = pass.context;
    var index = (await db.backupProfile(context))['scan_index'] as int? ?? 0;
    var scanned = 0;
    while (scanned < _scanLimit &&
        pass.prepared < BackupStaging.maxPreparedItems &&
        !_outOfTime(pass)) {
      if (!await _canPrepare(pass)) return;
      await _check(pass);
      final batch = await media.backupAssets(
        photos: context.settings.photos,
        videos: context.settings.videos,
        start: index,
        count: _pageSize,
      );
      if (batch.isEmpty) {
        await _finishScan(pass);
        return;
      }
      for (final asset in batch) {
        if (_outOfTime(pass) ||
            pass.prepared >= BackupStaging.maxPreparedItems ||
            !await _canPrepare(pass)) {
          return;
        }
        await _check(pass);
        final kind = asset.type == AssetType.video
            ? BackupSourceKind.video
            : BackupSourceKind.photo;
        if ((asset.type == AssetType.image && context.settings.photos) ||
            (asset.type == AssetType.video && context.settings.videos)) {
          try {
            await _scanAsset(pass, tus, recoverable, asset, kind);
          } catch (error) {
            final failure = _failure(error);
            if (failure.code == 'staging_budget' ||
                failure.code == 'context_changed' ||
                failure.code == 'lease_lost' ||
                failure.code == 'policy') {
              rethrow;
            }
            if (failure.waiting) {
              pass.waiting = failure.message;
            } else {
              pass.error = failure.message;
              pass.failed++;
            }
            await _writeProfile(pass, {
              'scan_error': failure.message,
              'waiting_reason': pass.waiting,
              'error': pass.error,
            });
          }
        }
        index++;
        scanned++;
        await _writeProfile(pass, {
          'scan_index': index,
          'skipped': pass.skipped,
        });
      }
      if (batch.length < _pageSize) {
        await _finishScan(pass);
        return;
      }
    }
    await _writeProfile(pass, {'needs_scan': 1});
  }

  Future<void> _scanAsset(
    _Pass pass,
    BackupTusService tus,
    bool recoverable,
    AssetEntity asset,
    BackupSourceKind kind,
  ) async {
    final context = pass.context;
    final destination = backupDestinationId(context);
    if (await db.isOwnedAssetBackedUp(
      profileId: context.profileId,
      destinationId: destination,
      assetId: asset.id,
    )) {
      pass.skipped++;
      pass.report();
      return;
    }
    if (await db.backupJobForAsset(context.profileId, destination, asset.id) !=
        null) {
      return;
    }
    final source = await media.backupFile(asset);
    final name = await media.backupAssetName(asset, source);
    await _check(pass);
    await _checkSpace(await source.length());
    final job = await _newJob(pass, asset.id, kind, name);
    if (job == null) return;
    pass.prepared++;
    pass.preparedJobs.add(job.jobId);
    pass.report(name);
    try {
      final staged = await _staging.copySource(
        jobId: job.jobId,
        source: source,
        checkpoint: () => _check(pass, policy: false, throttle: true),
        maximumBytes: await _sourceAllowance(job),
      );
      await _saveStaged(pass, job, staged);
      await _processJob(
        pass,
        tus,
        recoverable,
        (await db.backupJob(job.jobId))!,
      );
    } catch (error) {
      await _jobFailure(pass, job, _failure(error));
      rethrow;
    }
  }

  Future<BackupJob?> _newJob(
    _Pass pass,
    String assetId,
    BackupSourceKind kind,
    String filename,
  ) async {
    await _check(pass);
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.contains(RegExp(r'[/\\\x00]'))) {
      throw BackupFailure(
        'A media item has an invalid filename.',
        code: 'source_name',
        retryable: false,
      );
    }
    final context = pass.context;
    final id = newBackupId();
    final root = await _staging.root();
    final directory = p.join(root.path, id);
    return db.createBackupJob(
      BackupJob(
        jobId: id,
        instanceId: context.instance.id,
        profileId: context.profileId,
        userId: context.userId,
        destinationId: backupDestinationId(context),
        assetId: assetId,
        sourceKind: kind,
        drive: context.settings.driveUuid!,
        remotePath: backupJoin(
          backupFolder(context.settings.folder),
          backupSourceFolder(kind),
        ),
        filename: filename,
        generation: context.generation,
        localPath: p.join(directory, 'source'),
        stageDirectory: directory,
        createdAt: _now(),
      ),
      pass.owner,
      _now(),
    );
  }

  Future<void> _scanContacts(
    _Pass pass,
    BackupTusService tus,
    bool recoverable,
  ) async {
    final state = await db.backupProfile(pass.context);
    if (state['contacts_scanned'] == 1) return;
    if (_outOfTime(pass) || !await _canPrepare(pass)) return;
    final day = DateTime.now().toIso8601String().split('T').first;
    final assetId = 'contacts-$day';
    final context = pass.context;
    final destination = backupDestinationId(context);
    if (await db.isOwnedAssetBackedUp(
      profileId: context.profileId,
      destinationId: destination,
      assetId: assetId,
    )) {
      pass.skipped++;
    } else {
      var job = await db.backupJobForAsset(
        context.profileId,
        destination,
        assetId,
      );
      if (job == null) {
        job = await _newJob(
          pass,
          assetId,
          BackupSourceKind.contacts,
          '$assetId.vcf',
        );
        if (job != null) {
          pass.prepared++;
          pass.preparedJobs.add(job.jobId);
        }
      }
      if (job != null) await _processJob(pass, tus, recoverable, job);
    }
    await _writeProfile(pass, {'contacts_scanned': 1, 'skipped': pass.skipped});
  }

  Future<void> _finishScan(_Pass pass) async {
    await _check(pass, policy: false);
    final state = await db.backupProfile(pass.context);
    if (state['contacts_scanned'] != 1) {
      await _writeProfile(pass, {'needs_scan': 1});
      return;
    }
    final scanError = state['scan_error'] as String?;
    await _writeProfile(pass, {
      'needs_scan': 0,
      'scan_complete': scanError == null ? 1 : 0,
      'scan_finished_at': _now().toIso8601String(),
      'skipped': pass.skipped,
      if (scanError != null) ...{
        'waiting_reason': pass.waiting,
        'error': pass.error,
        'next_retry_at': _now()
            .add(const Duration(minutes: 15))
            .toIso8601String(),
      },
    });
  }

  bool _outOfTime(_Pass pass) => !_now().isBefore(pass.deadline);

  Future<bool> _canPrepare(_Pass pass) async {
    if (pass.transfers >= BackupStaging.maxPreparedItems) {
      await _writeProfile(pass, {'needs_scan': 1});
      return false;
    }
    final jobs = (await db.backupJobs(
      profileId: pass.context.profileId,
      destinationId: backupDestinationId(pass.context),
    )).where((job) => _sourceEnabled(job, pass.context)).toList();
    if (jobs.length >= BackupStaging.maxPreparedItems) {
      final blocked = jobs.every((job) => job.state == BackupJobState.failed);
      await _writeProfile(pass, {
        'needs_scan': blocked ? 0 : 1,
        if (blocked) ...{
          'scan_complete': 0,
          'scan_error':
              'Resolve the failed backup jobs before preparing more files.',
        },
      });
      return false;
    }
    return true;
  }

  Future<void> _checkSpace(int size, {BackupJob? existing}) async {
    final occupied = math.max(
      await db.ownedStagingBytes(),
      await _staging.usedBytes(),
    );
    final count = await db.stagedBackupJobCount();
    final ownBytes = existing == null
        ? 0
        : math.max(existing.size ?? 0, await _staging.usedBytes(job: existing));
    final otherCount = count - (existing?.stageDirectory == null ? 0 : 1);
    if (otherCount > 0 &&
        occupied - ownBytes + size > BackupStaging.targetBytes) {
      throw BackupFailure(
        'Waiting for staged uploads to finish before preparing more files.',
        code: 'staging_budget',
        waiting: true,
      );
    }
  }

  Future<int?> _sourceAllowance(BackupJob job) async {
    final count = await db.stagedBackupJobCount();
    if (count <= 1) return null;
    final occupied = math.max(
      await db.ownedStagingBytes(),
      await _staging.usedBytes(),
    );
    final ownBytes = math.max(
      job.size ?? 0,
      await _staging.usedBytes(job: job),
    );
    return math.max(0, BackupStaging.targetBytes - occupied + ownBytes);
  }

  Future<void> _saveStaged(
    _Pass pass,
    BackupJob job,
    StagedBackupSource source,
  ) async {
    if (job.sha256 != null &&
        (job.sha256 != source.sha256 || job.size != source.size)) {
      throw BackupFailure(
        'The source changed while its upload was interrupted.',
        code: 'source_changed',
        retryable: false,
      );
    }
    if (source.size == 0) {
      throw BackupFailure(
        'The backup source is empty or unavailable.',
        code: 'source_empty',
        retryable: false,
      );
    }
    await _check(pass, policy: false);
    if (!await db.claimBackupJob(job, pass.owner, _now()) ||
        !await db.updateBackupJob(job.jobId, {
          'local_path': source.path,
          'stage_directory': source.directory,
          'size': source.size,
          'sha256': source.sha256,
          'status': BackupJobState.ready.name,
          'error': null,
          'error_code': null,
        }, leaseOwner: pass.owner)) {
      throw BackupFailure(
        'Backup paused before the staged source could be claimed.',
        code: 'lease_lost',
        waiting: true,
      );
    }
  }

  Future<BackupJob?> _prepareExisting(_Pass pass, BackupJob job) async {
    await _check(pass);
    if (!pass.preparedJobs.contains(job.jobId)) {
      if (pass.prepared >= BackupStaging.maxPreparedItems) {
        throw BackupFailure(
          'Backup preparation will continue in the next execution window.',
          code: 'pass_budget',
          waiting: true,
        );
      }
      pass.prepared++;
      pass.preparedJobs.add(job.jobId);
    }
    if (!job.staged) {
      final recovered = await _staging.recoverSource(
        job,
        checkpoint: () => _check(pass, policy: false, throttle: true),
      );
      if (recovered != null) {
        await _saveStaged(pass, job, recovered);
        return db.backupJob(job.jobId);
      }
    }
    StagedBackupSource staged;
    if (job.sourceKind == BackupSourceKind.contacts) {
      final directory = await _staging.directoryFor(job.jobId);
      final count = await media.exportBackupContacts(
        directory,
        maximumBytes: await _sourceAllowance(job),
        checkpoint: () async {
          await _check(pass, policy: false, throttle: true);
          if (_outOfTime(pass)) {
            throw BackupFailure(
              'Contacts preparation will continue in the next backup window.',
              code: 'pass_budget',
              waiting: true,
            );
          }
        },
      );
      if (count == 0) {
        await db.updateBackupJob(job.jobId, {
          'status': BackupJobState.cancelled.name,
        }, leaseOwner: pass.owner);
        await _staging.cleanup(job);
        await db.markBackupStagingCleaned(job.jobId);
        pass.skipped++;
        return null;
      }
      staged = await _staging.adoptContacts(
        jobId: job.jobId,
        source: File(p.join(directory.path, 'contacts.export')),
        checkpoint: () => _check(pass, policy: false, throttle: true),
        maximumBytes: await _sourceAllowance(job),
      );
    } else {
      final asset = await media.backupAsset(job.assetId);
      if (asset == null) {
        throw BackupFailure(
          'The original media item is no longer accessible.',
          code: 'media_missing',
          waiting: true,
        );
      }
      final file = await media.backupFile(asset);
      await _checkSpace(await file.length(), existing: job);
      staged = await _staging.copySource(
        jobId: job.jobId,
        source: file,
        checkpoint: () => _check(pass, policy: false, throttle: true),
        maximumBytes: await _sourceAllowance(job),
      );
    }
    await _saveStaged(pass, job, staged);
    return db.backupJob(job.jobId);
  }

  Future<void> _processJob(
    _Pass pass,
    BackupTusService tus,
    bool serverRecoverable,
    BackupJob original,
  ) async {
    if (pass.visited.contains(original.jobId)) return;
    if ((await _pending()).any((task) => task.jobId == original.jobId)) return;
    await _check(pass);
    if (!await db.claimBackupJob(original, pass.owner, _now())) return;
    pass.visited.add(original.jobId);
    var job = (await db.backupJob(original.jobId))!;
    if (job.terminal) return;
    pass.report(job.filename);
    try {
      if (job.generation != pass.context.generation) {
        if (!await db.updateBackupJob(job.jobId, {
          'generation': pass.context.generation,
        }, leaseOwner: pass.owner)) {
          throw BackupFailure(
            'The backup job was paused before recovery.',
            code: 'lease_lost',
            waiting: true,
          );
        }
        job = (await db.backupJob(job.jobId))!;
      }
      if (!job.staged) {
        final prepared = await _prepareExisting(pass, job);
        if (prepared == null) return;
        job = prepared;
      }
      final recoverable = job.recoverable ?? serverRecoverable;
      if (!recoverable && !pass.manual) {
        throw BackupFailure(
          legacyReason,
          code: 'legacy_server',
          retryable: false,
          waiting: true,
        );
      }
      await db.updateBackupJob(job.jobId, {
        'recoverable': recoverable ? 1 : 0,
      }, leaseOwner: pass.owner);
      job = (await db.backupJob(job.jobId))!;
      await _check(pass);
      var receipt = recoverable ? await tus.receipt(job) : null;
      if (await _handleReceipt(pass, job, receipt)) return;
      var url = receipt != null
          ? tus.uploadUrl(receipt.uploadUrl)
          : (job.tusUrl == null ? null : tus.uploadUrl(job.tusUrl!));
      if (url == null) {
        await _check(pass);
        url = await tus.create(job, recoverable: recoverable);
        if (url == null) {
          receipt = await tus.receipt(job);
          if (await _handleReceipt(pass, job, receipt)) return;
          if (receipt == null) {
            throw BackupFailure(
              'The server reported an upload conflict without a recovery record.',
              code: 'create_conflict',
            );
          }
          url = tus.uploadUrl(receipt.uploadUrl);
        }
        await _saveResource(pass, job, url);
      }
      await _check(pass);
      var offset = await tus.head(job, url);
      if (offset == null && recoverable) {
        receipt = await tus.receipt(job);
        if (await _handleReceipt(pass, job, receipt)) return;
        if (receipt == null) {
          await _check(pass);
          final recreated = await tus.create(job, recoverable: true);
          if (recreated != null) {
            url = recreated;
          } else {
            receipt = await tus.receipt(job);
            if (await _handleReceipt(pass, job, receipt)) return;
            if (receipt == null) {
              throw BackupFailure(
                'The server upload could not be recovered.',
                code: 'upload_missing',
              );
            }
            url = tus.uploadUrl(receipt.uploadUrl);
          }
        } else {
          url = tus.uploadUrl(receipt.uploadUrl);
        }
        await _saveResource(pass, job, url);
        await _check(pass);
        offset = await tus.head(job, url);
      }
      if (offset == null) {
        throw BackupFailure(
          recoverable
              ? 'The server has the backup record but its upload data is unavailable.'
              : 'This legacy server cannot verify an interrupted upload. '
                    'Update the server and cancel this job before starting again.',
          code: recoverable ? 'upload_missing' : 'legacy_ambiguous',
          retryable: recoverable,
        );
      }
      if (offset == job.size) {
        if (recoverable) {
          receipt = await tus.receipt(job);
          if (await _handleReceipt(pass, job, receipt)) return;
          await _awaitReceipt(pass, job);
          return;
        }
        throw BackupFailure(
          'This legacy server cannot confirm the final result of an interrupted '
          'upload. It has not been counted as backed up.',
          code: 'legacy_ambiguous',
          retryable: false,
        );
      }
      await _check(pass);
      if (!await db.updateBackupJob(job.jobId, {
        'tus_url': url.toString(),
        'tus_offset': offset,
        'status': BackupJobState.ready.name,
      }, leaseOwner: pass.owner)) {
        throw BackupFailure(
          'The backup job was paused before transfer.',
          code: 'lease_lost',
          waiting: true,
        );
      }
      job = (await db.backupJob(job.jobId))!;
      try {
        await _staging.verifySource(
          job,
          checkpoint: () => _check(pass, policy: false, throttle: true),
        );
      } on BackupFailure catch (error) {
        if (error.code != 'source_missing') rethrow;
        final prepared = await _prepareExisting(pass, job);
        if (prepared == null) return;
        job = prepared;
      }
      if (recoverable && backgroundUploads.isSupported) {
        await _enqueueNative(pass, tus, job);
      } else {
        await _uploadForeground(pass, tus, job, recoverable);
      }
    } catch (error) {
      var failure = _failure(error);
      final current = await db.backupJob(job.jobId);
      if (current == null || current.terminal) return;
      if (current.recoverable == true &&
          current.staged &&
          failure.code != 'context_changed' &&
          failure.code != 'lease_lost' &&
          failure.code != 'policy') {
        try {
          final receipt = await tus.receipt(current);
          if (receipt?.state == 'complete') {
            await _complete(pass, current, receipt!);
            return;
          }
        } catch (recoveryError) {
          final recoveryFailure = _failure(recoveryError);
          if (!recoveryFailure.retryable) {
            failure = recoveryFailure;
          }
        }
      }
      await _jobFailure(pass, current, failure);
      if (failure.code == 'context_changed' ||
          failure.code == 'lease_lost' ||
          failure.code == 'policy') {
        rethrow;
      }
    } finally {
      pass.report();
    }
  }

  Future<void> _saveResource(_Pass pass, BackupJob job, Uri url) async {
    await _check(pass, policy: false);
    if (!await db.updateBackupJob(job.jobId, {
      'tus_url': url.toString(),
    }, leaseOwner: pass.owner)) {
      throw BackupFailure(
        'The backup account changed while creating an upload.',
        code: 'context_changed',
        waiting: true,
      );
    }
  }

  Future<bool> _handleReceipt(
    _Pass pass,
    BackupJob job,
    BackupReceipt? receipt,
  ) async {
    if (receipt == null) return false;
    receipt.validate(job);
    if (receipt.state == 'complete') {
      await _complete(pass, job, receipt);
      return true;
    }
    if (receipt.state == 'finalizing') {
      await _awaitReceipt(pass, job);
      return true;
    }
    if (receipt.state == 'failed') {
      throw BackupFailure(
        'The server could not finalize this backup. Check the drive and retry.',
        code: 'server_job_failed',
        retryable: false,
      );
    }
    return false;
  }

  Future<void> _complete(
    _Pass pass,
    BackupJob job,
    BackupReceipt receipt,
  ) async {
    final before = await db.backupJob(job.jobId);
    await db.completeBackupJob(
      job.jobId,
      receipt.remotePath,
      _now(),
      receipt: receipt,
    );
    final after = await db.backupJob(job.jobId);
    if (before?.state != BackupJobState.complete &&
        after?.state == BackupJobState.complete) {
      pass.uploaded++;
    }
    await _cleanupOwned();
  }

  Future<void> _awaitReceipt(_Pass pass, BackupJob job) async {
    await db.updateBackupJob(job.jobId, {
      'status': BackupJobState.reconciling.name,
      'retry_at': _now().add(const Duration(seconds: 30)).toIso8601String(),
      'error': null,
      'error_code': null,
    }, leaseOwner: pass.owner);
    pass.waiting = 'Waiting for the server to verify and finalize the backup.';
    await _writeProfile(pass, {'waiting_reason': pass.waiting});
  }

  Future<void> _enqueueNative(
    _Pass pass,
    BackupTusService tus,
    BackupJob job,
  ) async {
    // Never infer a vanished native task from its age.
    if ((await backgroundUploads.pending()).any(
      (task) => task.jobId == job.jobId,
    )) {
      return;
    }
    await _staging.removeUnusedSuffixes(job);
    await db.updateBackupJob(job.jobId, {
      'suffix_path': null,
      'suffix_offset': null,
    }, leaseOwner: pass.owner);
    job = (await db.backupJob(job.jobId))!;
    final remaining = job.size! - job.offset;
    final occupied = math.max(
      await db.ownedStagingBytes(),
      await _staging.usedBytes(),
    );
    final count = await db.stagedBackupJobCount();
    final allowance = count <= 1 ? null : BackupStaging.targetBytes - occupied;
    if (job.offset > 0 && allowance != null && remaining > allowance) {
      throw BackupFailure(
        'Waiting for staging space to resume this partial upload.',
        code: 'staging_budget',
        waiting: true,
      );
    }
    final body = await _staging.suffix(
      job,
      job.offset,
      checkpoint: () => _check(pass, policy: false, throttle: true),
      maximumBytes: allowance,
    );
    await _check(pass);
    await db.updateBackupJob(job.jobId, {
      'suffix_path': job.offset == 0 ? null : body,
      'suffix_offset': job.offset == 0 ? null : job.offset,
    }, leaseOwner: pass.owner);
    final attemptId = newBackupId();
    if (!await db.claimBackupJob(job, pass.owner, _now()) ||
        !await db.startBackupAttempt(
          job: job,
          attemptId: attemptId,
          transport: 'native',
          leaseOwner: pass.owner,
          generation: pass.context.generation,
          now: _now(),
        )) {
      throw BackupFailure(
        'Backup paused before its native transfer could be claimed.',
        code: 'lease_lost',
        waiting: true,
      );
    }
    await _check(pass);
    final task = await backgroundUploads.enqueue(
      jobId: job.jobId,
      attemptId: attemptId,
      url: tus.uploadUrl(job.tusUrl!),
      localPath: body,
      offset: job.offset,
      totalBytes: job.size!,
      headers: tus.patchHeaders(job),
      wifiOnly: pass.context.settings.wifiOnly,
      trustSelfSigned: pass.context.instance.trustSelfSigned,
      trustedOrigin: pass.context.instance.baseUrl,
    );
    await db.recordNativeEnqueue(
      jobId: job.jobId,
      attemptId: attemptId,
      taskId: task.taskId,
      sessionId: task.sessionId,
    );
    pass.transfers++;
    if (!await _isActive(pass.context)) {
      final current = await db.backupJob(job.jobId);
      if (current?.attemptId == attemptId &&
          current?.generation == pass.context.generation) {
        await db.updateBackupJob(job.jobId, {
          'status': BackupJobState.paused.name,
        }, attemptId: attemptId);
        await backgroundUploads.cancel([job.jobId]);
      }
    }
  }

  Future<void> _uploadForeground(
    _Pass pass,
    BackupTusService tus,
    BackupJob job,
    bool recoverable,
  ) async {
    await _check(pass);
    final attempt = newBackupId();
    if (!await db.claimBackupJob(job, pass.owner, _now()) ||
        !await db.startBackupAttempt(
          job: job,
          attemptId: attempt,
          transport: recoverable ? 'foreground' : 'legacy',
          leaseOwner: pass.owner,
          generation: pass.context.generation,
          now: _now(),
        )) {
      throw BackupFailure(
        'Backup paused before its foreground transfer could be claimed.',
        code: 'lease_lost',
        waiting: true,
      );
    }
    pass.transfers++;
    final completed = await tus.uploadForeground(
      job: job,
      beforeTransfer: () async {
        await _check(pass);
        if (!await db.claimBackupJob(job, pass.owner, _now())) {
          throw BackupFailure(
            'The backup transfer was paused.',
            code: 'lease_lost',
            waiting: true,
          );
        }
      },
      onOffset: (offset) async {
        if (!await db.updateBackupJob(
          job.jobId,
          {'tus_offset': offset},
          leaseOwner: pass.owner,
          attemptId: attempt,
        )) {
          throw BackupFailure(
            'The backup account changed during transfer.',
            code: 'context_changed',
            waiting: true,
          );
        }
      },
      onProgress: (_) => pass.report(job.filename),
    );
    if (recoverable) {
      final receipt = await tus.receipt(job);
      if (await _handleReceipt(pass, job, receipt)) return;
      await _awaitReceipt(pass, job);
    } else if (completed) {
      await db.completeBackupJob(
        job.jobId,
        backupJoin(job.remotePath, job.filename),
        _now(),
      );
      if ((await db.backupJob(job.jobId))?.state == BackupJobState.complete) {
        pass.uploaded++;
      }
      await _cleanupOwned();
    } else {
      throw BackupFailure(
        'The foreground upload did not confirm completion.',
        code: 'legacy_incomplete',
        retryable: false,
      );
    }
  }

  DateTime? _retryAt(BackupJob job, BackupFailure failure) {
    if (!failure.retryable) return null;
    if (failure.code == 'staging_budget') {
      return _now().add(const Duration(minutes: 2));
    }
    final seconds = math.min(1800, 30 * (1 << math.min(job.failureCount, 6)));
    return _now().add(Duration(seconds: seconds));
  }

  Future<void> _jobFailure(
    _Pass pass,
    BackupJob original,
    BackupFailure failure,
  ) async {
    final job = await db.backupJob(original.jobId);
    if (job == null || job.terminal || job.state == BackupJobState.paused) {
      return;
    }
    final pause =
        failure.code == 'context_changed' ||
        failure.code == 'lease_lost' ||
        failure.code == 'policy';
    await db.updateBackupJob(job.jobId, {
      'status': pause
          ? BackupJobState.paused.name
          : (failure.retryable
                ? BackupJobState.retry.name
                : BackupJobState.failed.name),
      'error': failure.message,
      'error_code': failure.code,
      'failure_count': job.failureCount + 1,
      'retry_at': pause ? null : _retryAt(job, failure)?.toIso8601String(),
    }, leaseOwner: pass.owner);
    if (failure.waiting) {
      pass.waiting = failure.message;
    } else {
      pass.error = failure.message;
      pass.failed++;
    }
    await _writeProfile(pass, {
      'error': pass.error,
      'waiting_reason': pass.waiting,
    });
  }

  Future<void> reconcileCompletions() async {
    const key = 'native-completions';
    final owner = newBackupId();
    final deadline = _now().add(const Duration(seconds: 90));
    if (!await db.acquireBackupLease(key, owner, _now())) return;
    try {
      if (backgroundUploads.isSupported) {
        final events = await backgroundUploads.readCompletions();
        for (final event in events.take(BackupStaging.maxPreparedItems)) {
          if (!_now().isBefore(deadline)) break;
          if (!await db.renewBackupLease(key, owner, _now())) return;
          final job = await db.backupJob(event.jobId);
          BackupReceipt? receipt;
          BackupFailure? failure = _nativeFailure(event, job);
          if (job != null &&
              !job.terminal &&
              job.attemptId == event.attemptId &&
              job.recoverable == true &&
              job.staged) {
            try {
              final context = await _matchingReceiptContext(job);
              if (context != null) {
                final tus = _tusFactory(context);
                try {
                  if (event.responseUrl != null) {
                    tus.uploadUrl(event.responseUrl!);
                  }
                  receipt = await tus.receipt(job);
                  if (receipt?.state == 'failed') {
                    failure = BackupFailure(
                      'The server could not finalize this backup. '
                      'Check the destination drive and retry.',
                      code: 'server_job_failed',
                      retryable: false,
                    );
                  } else if (receipt?.state == 'finalizing') {
                    failure = null;
                  }
                } finally {
                  tus.close();
                }
              }
            } catch (error) {
              failure = _failure(error);
            }
          }
          await db.recordNativeCompletion(
            eventId: event.eventId,
            jobId: event.jobId,
            attemptId: event.attemptId,
            statusCode: event.statusCode,
            offset: event.uploadOffset,
            cancelled: event.cancelled,
            errorCode: event.errorCode,
            completedAt: event.completedAt,
            receipt: receipt?.state == 'complete' ? receipt : null,
            failure: failure,
            retryAt: job == null
                ? null
                : (failure == null
                      ? _now().add(const Duration(seconds: 30))
                      : _retryAt(job, failure)),
          );
          // If the transaction or ACK fails, native retains the event for replay.
          await backgroundUploads.ackCompletions([event.eventId]);
        }
      }
      await _reconcileReceiptJobs(await _pending(), deadline);
      await _cleanupOwned();
    } finally {
      await db.releaseBackupLease(key, owner);
    }
  }

  Future<BackupContext?> _matchingReceiptContext(BackupJob job) async {
    final context = await _receiptContext(job);
    if (context == null ||
        context.instance.id != job.instanceId ||
        context.userId != job.userId ||
        context.profileId != job.profileId) {
      return null;
    }
    return context;
  }

  BackupFailure? _nativeFailure(NativeUploadCompletion event, BackupJob? job) {
    if (event.cancelled) {
      return BackupFailure(
        'The native transfer was cancelled. Its server offset will be recovered.',
        code: 'native_cancelled',
        waiting: true,
      );
    }
    final status = event.statusCode;
    if (status != null && (status < 200 || status >= 300)) {
      return backupHttpFailure(status);
    }
    if (event.errorCode != null ||
        event.errorMessage != null ||
        status == null) {
      return BackupFailure(
        'The native upload was interrupted. Waiting to recover the server result.',
        code: 'native_transport',
        isNetwork: true,
      );
    }
    if (job != null && event.totalBytes != job.size) {
      return BackupFailure(
        'The native completion does not match this backup file.',
        code: 'native_size',
        retryable: false,
      );
    }
    if (status != 204 ||
        event.uploadOffset == null ||
        event.uploadOffset != event.totalBytes) {
      return BackupFailure(
        'The native upload did not confirm all bytes. Its offset will be checked.',
        code: 'native_partial',
      );
    }
    return null;
  }

  Future<void> _reconcileReceiptJobs(
    List<NativeUploadTask> pending,
    DateTime deadline,
  ) async {
    final jobs = await db.backupJobs();
    var checked = 0;
    for (var job in jobs) {
      if (!_now().isBefore(deadline)) break;
      if (pending.any((task) => task.jobId == job.jobId)) continue;
      if (await db.hasBackupLease(job.profileId, _now())) continue;
      if (job.state == BackupJobState.uploading) {
        // Actual URLSession pending state, not a timestamp, permits recovery.
        final changed = await db.updateBackupJob(
          job.jobId,
          {
            'status': BackupJobState.reconciling.name,
            'native_task_id': null,
            'native_session_id': null,
          },
          attemptId: job.attemptId,
          expectedState: job.state,
        );
        if (!changed) continue;
        job = (await db.backupJob(job.jobId))!;
      }
      if (job.recoverable != true ||
          !job.staged ||
          job.state == BackupJobState.preparing ||
          job.state == BackupJobState.ready ||
          job.retryAt?.isAfter(_now()) == true) {
        continue;
      }
      if (checked >= BackupStaging.maxPreparedItems) break;
      final context = await _matchingReceiptContext(job);
      if (context == null) continue;
      if (job.state == BackupJobState.failed &&
          job.generation == context.generation) {
        continue;
      }
      checked++;
      final tus = _tusFactory(context);
      try {
        final receipt = await tus.receipt(job);
        if (receipt?.state == 'complete') {
          await db.completeBackupJob(
            job.jobId,
            receipt!.remotePath,
            _now(),
            receipt: receipt,
          );
        } else if (receipt?.state == 'failed') {
          await db.updateBackupJob(
            job.jobId,
            {
              'status': job.state == BackupJobState.paused
                  ? BackupJobState.paused.name
                  : BackupJobState.failed.name,
              'error':
                  'The server could not finalize this backup. '
                  'Check the drive and retry.',
              'error_code': 'server_job_failed',
              'retry_at': null,
            },
            attemptId: job.attemptId,
            expectedState: job.state,
          );
        } else if (receipt?.state == 'finalizing') {
          await db.updateBackupJob(
            job.jobId,
            {
              'status': job.state == BackupJobState.paused
                  ? BackupJobState.paused.name
                  : BackupJobState.reconciling.name,
              'retry_at': _now()
                  .add(const Duration(seconds: 30))
                  .toIso8601String(),
            },
            attemptId: job.attemptId,
            expectedState: job.state,
          );
        } else if (job.state != BackupJobState.paused &&
            job.state != BackupJobState.failed) {
          await db.updateBackupJob(
            job.jobId,
            {'status': BackupJobState.ready.name, 'retry_at': null},
            attemptId: job.attemptId,
            expectedState: job.state,
          );
        }
      } catch (error) {
        final failure = _failure(error);
        if (job.state != BackupJobState.paused) {
          await db.updateBackupJob(
            job.jobId,
            {
              'status': failure.retryable
                  ? BackupJobState.retry.name
                  : BackupJobState.failed.name,
              'error': failure.message,
              'error_code': failure.code,
              'failure_count': job.failureCount + 1,
              'retry_at': _retryAt(job, failure)?.toIso8601String(),
            },
            attemptId: job.attemptId,
            expectedState: job.state,
          );
        }
      } finally {
        tus.close();
      }
    }
  }

  Future<void> _cleanupOwned() async {
    final pending = await _pending();
    final unacked = backgroundUploads.isSupported
        ? await backgroundUploads.readCompletions()
        : const <NativeUploadCompletion>[];
    for (final job in await db.backupCleanupCandidates()) {
      if (pending.any((task) => task.jobId == job.jobId) ||
          unacked.any((event) => event.jobId == job.jobId)) {
        continue;
      }
      await _staging.cleanup(job);
      await db.markBackupStagingCleaned(job.jobId);
    }
  }

  /// Scan continuation is separate from resuming queued/paused transfers.
  /// Retry deadlines gate automatic passes, not native tasks already in flight.
  Future<BackupSnapshot> snapshot(BackupContext context) async {
    final state = await db.backupProfile(context);
    final jobs = (await db.backupJobs(
      profileId: context.profileId,
      destinationId: backupDestinationId(context),
    )).where((job) => _sourceEnabled(job, context)).toList();
    final pending = await _pending();
    var queued = 0;
    var uploading = 0;
    var paused = 0;
    var failed = 0;
    final needsScan =
        state['needs_scan'] == 1 ||
        state.isEmpty ||
        state['generation'] != context.generation ||
        state['source_mask'] != backupSourceMask(context);
    String? current;
    double? progress;
    String? error = state['error'] as String?;
    String? waiting = state['waiting_reason'] as String?;
    final profileRetry = state['generation'] == context.generation
        ? _date(state['next_retry_at'])
        : null;
    DateTime? jobRetry;
    var hasReadyJob = false;
    for (final job in jobs) {
      NativeUploadTask? task;
      for (final candidate in pending) {
        if (candidate.jobId == job.jobId) {
          task = candidate;
          if (candidate.attemptId == job.attemptId) break;
        }
      }
      final inFlight =
          task != null ||
          (job.state == BackupJobState.uploading && job.transport != 'native');
      final failedInThisGeneration =
          job.state == BackupJobState.failed &&
          job.generation == context.generation;
      if (inFlight) {
        uploading++;
        current ??= job.filename;
        progress ??= job.size == null || job.size == 0
            ? 0
            : ((task == null ? job.offset : task.offset + task.bytesSent) /
                      job.size!)
                  .clamp(0, 1)
                  .toDouble();
      } else if (job.state == BackupJobState.paused) {
        paused++;
      } else if (failedInThisGeneration) {
        failed++;
        error ??= job.error;
      } else {
        queued++;
      }
      if (!inFlight && !failedInThisGeneration) {
        final retry = job.generation == context.generation ? job.retryAt : null;
        if (retry == null) {
          hasReadyJob = true;
        } else if (jobRetry == null || retry.isBefore(jobRetry)) {
          jobRetry = retry;
        }
      }
      if (job.state == BackupJobState.reconciling) {
        waiting ??= 'Waiting for the server to verify the uploaded backup.';
      }
      if (job.error != null && job.state == BackupJobState.retry) {
        if (const {
          'staging_budget',
          'pass_budget',
          'media_cloud',
          'media_timeout',
          'media_missing',
          'local_storage',
          'native_cancelled',
        }.contains(job.errorCode)) {
          waiting ??= job.error;
        } else {
          error ??= job.error;
        }
      }
    }
    final scanHasCapacity =
        needsScan && jobs.length < BackupStaging.maxPreparedItems;
    DateTime? nextRetry;
    if (profileRetry != null && profileRetry.isAfter(_now())) {
      // A profile-wide connection/preparation backoff also gates ready jobs.
      nextRetry = profileRetry;
      if (!hasReadyJob &&
          !scanHasCapacity &&
          jobRetry != null &&
          jobRetry.isAfter(profileRetry)) {
        nextRetry = jobRetry;
      }
    } else if (!hasReadyJob && !scanHasCapacity) {
      nextRetry = profileRetry;
      if (jobRetry != null &&
          (nextRetry == null || jobRetry.isBefore(nextRetry))) {
        nextRetry = jobRetry;
      }
    }
    return BackupSnapshot(
      completed: await db.ownedBackedUpCount(
        context.profileId,
        backupDestinationId(context),
      ),
      queued: queued,
      uploading: uploading,
      paused: paused,
      failed: failed,
      skipped: state['skipped'] as int? ?? 0,
      lastAttemptAt: _date(state['last_attempt_at']),
      lastSuccessAt: _date(state['last_success_at']),
      error: error,
      waitingReason: waiting,
      current: current,
      progress: progress,
      needsScan: needsScan,
      nextRetryAt: nextRetry,
    );
  }

  Future<void> pauseProfile(String instanceId, int userId) =>
      cancelProfile(instanceId, userId);

  Future<void> cancelProfile(
    String instanceId,
    int userId, {
    bool discard = false,
  }) async {
    final profile = backupProfileKey(instanceId, userId);
    final owner = newBackupId();
    final jobs = await db.stopBackupProfile(
      profile,
      discard: discard,
      leaseOwner: owner,
      now: _now(),
    );
    try {
      if (backgroundUploads.isSupported && jobs.isNotEmpty) {
        await backgroundUploads.cancel(jobs.map((job) => job.jobId).toList());
      }
      if (discard) await _cleanupOwned();
    } finally {
      await db.releaseBackupLease(LocalDb.profileLock(profile), owner);
    }
  }

  Future<List<NativeUploadTask>> _pending() async =>
      backgroundUploads.isSupported ? backgroundUploads.pending() : [];

  static DateTime? _date(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  static BackupFailure _failure(Object error) {
    if (error is BackupFailure) return error;
    if (error is TimeoutException) {
      return BackupFailure(
        'Backup preparation timed out. The item will be retried later.',
        code: 'timeout',
        waiting: true,
      );
    }
    if (error is FileSystemException) {
      return BackupFailure(
        'Backup could not stage this file. Check free space and unlock the phone.',
        code: 'local_storage',
        waiting: true,
      );
    }
    return BackupFailure(
      backupFailureMessage(error),
      code: error is PlatformException
          ? 'platform_${error.code}'
          : 'unexpected',
      retryable:
          error is! FormatException &&
          error is! TypeError &&
          error is! StateError,
    );
  }
}
