import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/models/backup_context.dart';
import '../../data/models/backup_job.dart';

/// Local SQLite storage for the backup ledger (dedupe) and the upload queue.
///
/// Kept intentionally small; the schema is versioned so later phases can extend
/// it without data loss.
class LocalDb {
  LocalDb._(this._db);

  @visibleForTesting
  LocalDb.fromDatabase(this._db);

  static const schemaVersion = 3;
  static const leaseDuration = Duration(minutes: 2);

  final Database _db;
  Database get raw => _db;

  static Future<LocalDb> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'localdrive.db');
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) async {
        // Both setters return rows; Darwin's execute path requires SQLITE_DONE.
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
      onCreate: _onCreate,
      onUpgrade: migrate,
    );
    return LocalDb._(db);
  }

  static Future<void> _onCreate(Database db, int version) async {
    // A record of every asset already backed up, so re-runs skip duplicates.
    await db.execute('''
      CREATE TABLE backup_ledger (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        instance_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        name TEXT,
        size INTEGER,
        hash TEXT,
        remote_drive TEXT,
        remote_path TEXT,
        backed_up_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_ledger_asset
        ON backup_ledger (instance_id, asset_id)
    ''');

    // Pending / in-flight uploads (resumable via tus URL), survives relaunch.
    await db.execute('''
      CREATE TABLE upload_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        instance_id TEXT NOT NULL,
        drive TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        filename TEXT NOT NULL,
        local_path TEXT NOT NULL,
        size INTEGER,
        status TEXT NOT NULL DEFAULT 'pending',
        tus_url TEXT,
        error TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await migrate(db, 1, version);
  }

  /// Legacy rows deliberately remain unowned. They cannot prove that the
  /// selected account or destination already contains an asset.
  @visibleForTesting
  static Future<void> migrate(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2 && newVersion >= 2) {
      await _migrateToV2(db);
    }
    if (oldVersion < 3 && newVersion >= 3) {
      await db.execute(
        'ALTER TABLE backup_profile_state ADD COLUMN source_mask '
        'INTEGER NOT NULL DEFAULT 7',
      );
    }
  }

  static Future<void> _migrateToV2(Database db) async {
    for (final column in [
      'profile_id TEXT',
      'user_id INTEGER',
      'destination_id TEXT',
      'job_id TEXT',
    ]) {
      await db.execute('ALTER TABLE backup_ledger ADD COLUMN $column');
    }
    await db.execute('DROP INDEX idx_ledger_asset');
    await db.execute('''
      CREATE UNIQUE INDEX idx_ledger_legacy
        ON backup_ledger (instance_id, asset_id) WHERE user_id IS NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_ledger_owned
        ON backup_ledger (profile_id, destination_id, asset_id)
        WHERE user_id IS NOT NULL
    ''');
    for (final column in [
      'job_id TEXT',
      'profile_id TEXT',
      'user_id INTEGER',
      'destination_id TEXT',
      'asset_id TEXT',
      'source_kind TEXT',
      'generation INTEGER NOT NULL DEFAULT 0',
      'sha256 TEXT',
      'stage_directory TEXT',
      'suffix_path TEXT',
      'suffix_offset INTEGER',
      'tus_offset INTEGER NOT NULL DEFAULT 0',
      'attempt_id TEXT',
      'attempt_count INTEGER NOT NULL DEFAULT 0',
      'failure_count INTEGER NOT NULL DEFAULT 0',
      'native_task_id INTEGER',
      'native_session_id TEXT',
      'transport TEXT',
      'recoverable INTEGER',
      'retry_at TEXT',
      'claim_owner TEXT',
      'claim_until INTEGER',
      'updated_at TEXT',
      'completed_at TEXT',
      'remote_result_path TEXT',
      'error_code TEXT',
    ]) {
      await db.execute('ALTER TABLE upload_queue ADD COLUMN $column');
    }
    await db.execute('''
      CREATE UNIQUE INDEX idx_upload_job ON upload_queue(job_id)
        WHERE job_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX idx_upload_owned_asset
        ON upload_queue(profile_id, destination_id, asset_id)
        WHERE job_id IS NOT NULL AND status != 'cancelled'
    ''');
    await db.execute('''
      CREATE INDEX idx_upload_profile
        ON upload_queue(profile_id, destination_id, status, retry_at)
    ''');
    await db.execute('''
      CREATE TABLE backup_locks (
        lock_key TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE backup_profile_state (
        profile_id TEXT NOT NULL,
        destination_id TEXT NOT NULL,
        instance_id TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        drive TEXT NOT NULL,
        folder TEXT NOT NULL,
        generation INTEGER NOT NULL DEFAULT 0,
        scan_id TEXT,
        success_scan_id TEXT,
        scan_index INTEGER NOT NULL DEFAULT 0,
        contacts_scanned INTEGER NOT NULL DEFAULT 0,
        needs_scan INTEGER NOT NULL DEFAULT 1,
        scan_complete INTEGER NOT NULL DEFAULT 0,
        scan_error TEXT,
        scan_started_at TEXT,
        scan_finished_at TEXT,
        last_attempt_at TEXT,
        last_success_at TEXT,
        skipped INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        waiting_reason TEXT,
        next_retry_at TEXT,
        PRIMARY KEY (profile_id, destination_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE backup_attempts (
        attempt_id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL,
        offset INTEGER NOT NULL,
        total_bytes INTEGER NOT NULL,
        transport TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at TEXT NOT NULL,
        native_task_id INTEGER,
        native_session_id TEXT,
        completed_at TEXT,
        status_code INTEGER,
        error_code TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE backup_native_events (
        event_id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL,
        attempt_id TEXT NOT NULL,
        status_code INTEGER,
        upload_offset INTEGER,
        cancelled INTEGER NOT NULL,
        error_code TEXT,
        completed_at TEXT NOT NULL
      )
    ''');
  }

  // ---- Backup ledger -------------------------------------------------------
  Future<bool> isBackedUp(String instanceId, String assetId) async {
    final rows = await _db.query(
      'backup_ledger',
      columns: const ['id'],
      where: 'instance_id = ? AND asset_id = ? AND user_id IS NULL',
      whereArgs: [instanceId, assetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> markBackedUp({
    required String instanceId,
    required String assetId,
    String? name,
    int? size,
    String? hash,
    String? remoteDrive,
    String? remotePath,
  }) async {
    await _db.insert('backup_ledger', {
      'instance_id': instanceId,
      'asset_id': assetId,
      'name': name,
      'size': size,
      'hash': hash,
      'remote_drive': remoteDrive,
      'remote_path': remotePath,
      'backed_up_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> backedUpCount(String instanceId) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM backup_ledger '
      'WHERE instance_id = ? AND user_id IS NULL',
      [instanceId],
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  // ---- Upload queue --------------------------------------------------------
  Future<int> enqueueUpload({
    required String instanceId,
    required String drive,
    required String remotePath,
    required String filename,
    required String localPath,
    int? size,
  }) {
    return _db.insert('upload_queue', {
      'instance_id': instanceId,
      'drive': drive,
      'remote_path': remotePath,
      'filename': filename,
      'local_path': localPath,
      'size': size,
      'status': 'pending',
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> pendingUploads(String instanceId) {
    return _db.query(
      'upload_queue',
      where: "instance_id = ? AND job_id IS NULL AND status IN ('pending','error')",
      whereArgs: [instanceId],
      orderBy: 'id ASC',
    );
  }

  Future<void> updateUpload(int id, Map<String, Object?> values) {
    return _db.update('upload_queue', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearCompletedUploads(String instanceId) {
    return _db.delete(
      'upload_queue',
      where: "instance_id = ? AND job_id IS NULL AND status = 'done'",
      whereArgs: [instanceId],
    );
  }

  // ---- Account-owned backup jobs ------------------------------------------

  static String profileLock(String profileId) => 'profile:$profileId';

  Future<bool> acquireBackupLease(String key, String owner, DateTime now) =>
      _db.transaction((txn) async {
        await txn.insert('backup_locks', {
          'lock_key': key,
          'owner': owner,
          'expires_at': now.add(leaseDuration).millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        final changed = await txn.update(
          'backup_locks',
          {
            'owner': owner,
            'expires_at': now.add(leaseDuration).millisecondsSinceEpoch,
          },
          where: 'lock_key = ? AND (owner = ? OR expires_at <= ?)',
          whereArgs: [key, owner, now.millisecondsSinceEpoch],
        );
        return changed == 1;
      });

  Future<bool> renewBackupLease(String key, String owner, DateTime now) async =>
      await _db.update(
        'backup_locks',
        {'expires_at': now.add(leaseDuration).millisecondsSinceEpoch},
        where: 'lock_key = ? AND owner = ? AND expires_at > ?',
        whereArgs: [key, owner, now.millisecondsSinceEpoch],
      ) ==
      1;

  Future<void> releaseBackupLease(String key, String owner) =>
      _db.transaction((txn) async {
        await txn.delete(
          'backup_locks',
          where: 'lock_key = ? AND owner = ?',
          whereArgs: [key, owner],
        );
        await txn.update(
          'upload_queue',
          {'claim_owner': null, 'claim_until': null},
          where: 'job_id IS NOT NULL AND claim_owner = ?',
          whereArgs: [owner],
        );
      });

  Future<bool> _ownsLease(
    DatabaseExecutor txn,
    String profileId,
    String owner,
    DateTime now,
  ) async => (await txn.query(
    'backup_locks',
    columns: ['owner'],
    where: 'lock_key = ? AND owner = ? AND expires_at > ?',
    whereArgs: [profileLock(profileId), owner, now.millisecondsSinceEpoch],
  )).isNotEmpty;

  Future<bool> hasBackupLease(String profileId, DateTime now) async =>
      (await _db.query(
        'backup_locks',
        columns: ['owner'],
        where: 'lock_key = ? AND expires_at > ?',
        whereArgs: [profileLock(profileId), now.millisecondsSinceEpoch],
        limit: 1,
      )).isNotEmpty;

  Future<void> ensureBackupProfile(BackupContext context) async {
    await _db.insert('backup_profile_state', {
      'profile_id': context.profileId,
      'destination_id': backupDestinationId(context),
      'instance_id': context.instance.id,
      'user_id': context.userId,
      'drive': context.settings.driveUuid ?? '',
      'folder': backupFolder(context.settings.folder),
      'generation': context.generation,
      'source_mask': backupSourceMask(context),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<Map<String, Object?>> backupProfile(BackupContext context) async {
    final rows = await _db.query(
      'backup_profile_state',
      where: 'profile_id = ? AND destination_id = ?',
      whereArgs: [context.profileId, backupDestinationId(context)],
      limit: 1,
    );
    return rows.isEmpty ? <String, Object?>{} : rows.single;
  }

  Future<bool> updateBackupProfile(
    BackupContext context,
    Map<String, Object?> values, {
    String? leaseOwner,
    DateTime? now,
  }) async {
    await ensureBackupProfile(context);
    return _db.transaction((txn) async {
      if (leaseOwner != null &&
          !await _ownsLease(
            txn,
            context.profileId,
            leaseOwner,
            now ?? DateTime.now(),
          )) {
        return false;
      }
      return await txn.update(
            'backup_profile_state',
            values,
            where: 'profile_id = ? AND destination_id = ?',
            whereArgs: [context.profileId, backupDestinationId(context)],
          ) ==
          1;
    });
  }

  Future<Map<String, Object?>> beginBackupPass(
    BackupContext context,
    DateTime now,
    String leaseOwner,
  ) async {
    await ensureBackupProfile(context);
    final state = await backupProfile(context);
    final fresh =
        state['scan_id'] == null ||
        state['needs_scan'] == 0 ||
        state['generation'] != context.generation ||
        state['source_mask'] != backupSourceMask(context);
    final updated = await updateBackupProfile(
      context,
      {
        'last_attempt_at': now.toUtc().toIso8601String(),
        'generation': context.generation,
        'source_mask': backupSourceMask(context),
        'error': null,
        'waiting_reason': null,
        'next_retry_at': null,
        if (fresh) ...{
          'scan_id': newBackupId(),
          'scan_index': 0,
          'contacts_scanned': 0,
          'needs_scan': 1,
          'scan_complete': 0,
          'scan_error': null,
          'scan_started_at': now.toUtc().toIso8601String(),
          'scan_finished_at': null,
          'skipped': 0,
        },
      },
      leaseOwner: leaseOwner,
      now: now,
    );
    if (!updated) throw StateError('The backup pass lease was revoked.');
    return backupProfile(context);
  }

  Future<bool> isOwnedAssetBackedUp({
    required String profileId,
    required String destinationId,
    required String assetId,
  }) async => (await _db.query(
    'backup_ledger',
    columns: ['id'],
    where:
        'profile_id = ? AND destination_id = ? AND asset_id = ? '
        'AND user_id IS NOT NULL',
    whereArgs: [profileId, destinationId, assetId],
    limit: 1,
  )).isNotEmpty;

  Future<int> ownedBackedUpCount(
    String profileId,
    String destinationId,
  ) async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM backup_ledger '
          'WHERE profile_id = ? AND destination_id = ? AND user_id IS NOT NULL',
          [profileId, destinationId],
        ),
      ) ??
      0;

  Future<BackupJob?> backupJob(String jobId) async {
    final rows = await _db.query(
      'upload_queue',
      where: 'job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );
    return rows.isEmpty ? null : BackupJob.fromMap(rows.single);
  }

  Future<BackupJob?> backupJobForAsset(
    String profileId,
    String destinationId,
    String assetId,
  ) async {
    final rows = await _db.query(
      'upload_queue',
      where:
          "profile_id = ? AND destination_id = ? AND asset_id = ? "
          "AND job_id IS NOT NULL AND status != 'cancelled'",
      whereArgs: [profileId, destinationId, assetId],
      limit: 1,
    );
    return rows.isEmpty ? null : BackupJob.fromMap(rows.single);
  }

  Future<List<BackupJob>> backupJobs({
    String? profileId,
    String? destinationId,
    bool includeTerminal = false,
    int? limit,
  }) async {
    final rows = await _db.query(
      'upload_queue',
      where: [
        'job_id IS NOT NULL',
        if (profileId != null) 'profile_id = ?',
        if (destinationId != null) 'destination_id = ?',
        if (!includeTerminal) "status NOT IN ('complete','cancelled')",
      ].join(' AND '),
      whereArgs: [?profileId, ?destinationId],
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(BackupJob.fromMap).toList();
  }

  Future<BackupJob?> createBackupJob(
    BackupJob job,
    String leaseOwner,
    DateTime now,
  ) => _db.transaction((txn) async {
    if (!await _ownsLease(txn, job.profileId, leaseOwner, now)) return null;
    final ledger = await txn.query(
      'backup_ledger',
      columns: ['id'],
      where:
          'profile_id = ? AND destination_id = ? AND asset_id = ? '
          'AND user_id IS NOT NULL',
      whereArgs: [job.profileId, job.destinationId, job.assetId],
      limit: 1,
    );
    if (ledger.isNotEmpty) return null;
    await txn.insert('upload_queue', {
      ...job.toMap(),
      'claim_owner': leaseOwner,
      'claim_until': now.add(leaseDuration).millisecondsSinceEpoch,
      'updated_at': now.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final rows = await txn.query(
      'upload_queue',
      where: 'job_id = ? AND claim_owner = ?',
      whereArgs: [job.jobId, leaseOwner],
      limit: 1,
    );
    return rows.isEmpty ? null : BackupJob.fromMap(rows.single);
  });

  Future<bool> claimBackupJob(
    BackupJob job,
    String leaseOwner,
    DateTime now,
  ) => _db.transaction((txn) async {
    if (!await _ownsLease(txn, job.profileId, leaseOwner, now)) return false;
    return await txn.update(
          'upload_queue',
          {
            'claim_owner': leaseOwner,
            'claim_until': now.add(leaseDuration).millisecondsSinceEpoch,
          },
          where:
              "job_id = ? AND status NOT IN ('complete','cancelled') AND "
              '(claim_owner IS NULL OR claim_owner = ? OR claim_until <= ?)',
          whereArgs: [job.jobId, leaseOwner, now.millisecondsSinceEpoch],
        ) ==
        1;
  });

  Future<bool> updateBackupJob(
    String jobId,
    Map<String, Object?> values, {
    String? leaseOwner,
    String? attemptId,
    BackupJobState? expectedState,
  }) async =>
      await _db.update(
        'upload_queue',
        {...values, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        where: [
          'job_id = ?',
          "status NOT IN ('complete','cancelled')",
          if (leaseOwner != null) 'claim_owner = ?',
          if (leaseOwner != null)
            "EXISTS (SELECT 1 FROM backup_locks WHERE "
                "lock_key = 'profile:' || upload_queue.profile_id AND owner = ? "
                'AND expires_at > ?)',
          if (attemptId != null) 'attempt_id = ?',
          if (expectedState != null) 'status = ?',
        ].join(' AND '),
        whereArgs: [
          jobId,
          ?leaseOwner,
          ?leaseOwner,
          if (leaseOwner != null) DateTime.now().millisecondsSinceEpoch,
          ?attemptId,
          ?expectedState?.name,
        ],
      ) ==
      1;

  Future<bool> startBackupAttempt({
    required BackupJob job,
    required String attemptId,
    required String transport,
    required String leaseOwner,
    required int generation,
    required DateTime now,
  }) => _db.transaction((txn) async {
    if (!await _ownsLease(txn, job.profileId, leaseOwner, now)) return false;
    final changed = await txn.update(
      'upload_queue',
      {
        'attempt_id': attemptId,
        'attempt_count': job.attemptCount + 1,
        'status': BackupJobState.uploading.name,
        'transport': transport,
        'generation': generation,
        'error': null,
        'error_code': null,
        'retry_at': null,
        'native_task_id': null,
        'native_session_id': null,
        'updated_at': now.toUtc().toIso8601String(),
      },
      where:
          "job_id = ? AND claim_owner = ? AND claim_until > ? "
          "AND status NOT IN ('complete','cancelled')",
      whereArgs: [job.jobId, leaseOwner, now.millisecondsSinceEpoch],
    );
    if (changed != 1) return false;
    await txn.insert('backup_attempts', {
      'attempt_id': attemptId,
      'job_id': job.jobId,
      'offset': job.offset,
      'total_bytes': job.size,
      'transport': transport,
      'state': 'submitting',
      'created_at': now.toUtc().toIso8601String(),
    });
    return true;
  });

  Future<void> recordNativeEnqueue({
    required String jobId,
    required String attemptId,
    required int taskId,
    required String sessionId,
  }) => _db.transaction((txn) async {
    await txn.update(
      'backup_attempts',
      {
        'state': 'uploading',
        'native_task_id': taskId,
        'native_session_id': sessionId,
      },
      where: "attempt_id = ? AND state = 'submitting'",
      whereArgs: [attemptId],
    );
    await txn.update(
      'upload_queue',
      {'native_task_id': taskId, 'native_session_id': sessionId},
      where: "job_id = ? AND attempt_id = ? AND status = 'uploading'",
      whereArgs: [jobId, attemptId],
    );
  });

  /// The caller ACKs native only after this transaction commits. A replay or a
  /// late event for an older attempt cannot regress a newer attempt.
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
  }) => _db.transaction((txn) async {
    final existing = await txn.query(
      'backup_native_events',
      columns: ['event_id'],
      where: 'event_id = ?',
      whereArgs: [eventId],
    );
    if (existing.isNotEmpty) return;
    await txn.insert('backup_native_events', {
      'event_id': eventId,
      'job_id': jobId,
      'attempt_id': attemptId,
      'status_code': statusCode,
      'upload_offset': offset,
      'cancelled': cancelled ? 1 : 0,
      'error_code': errorCode,
      'completed_at': completedAt.toUtc().toIso8601String(),
    });
    await txn.update(
      'backup_attempts',
      {
        'state': cancelled ? 'cancelled' : 'finished',
        'completed_at': completedAt.toUtc().toIso8601String(),
        'status_code': statusCode,
        'error_code': errorCode,
      },
      where: 'attempt_id = ? AND job_id = ?',
      whereArgs: [attemptId, jobId],
    );
    final rows = await txn.query(
      'upload_queue',
      where: 'job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final job = BackupJob.fromMap(rows.single);
    if (job.terminal || job.attemptId != attemptId) return;
    if (receipt?.state == 'complete') {
      receipt!.validate(job);
      await _completeJob(txn, job, receipt.remotePath, completedAt);
      return;
    }
    if (job.state == BackupJobState.paused) return;
    await txn.update(
      'upload_queue',
      {
        'status': failure == null
            ? BackupJobState.reconciling.name
            : (failure.retryable
                  ? BackupJobState.retry.name
                  : BackupJobState.failed.name),
        if (offset != null && offset >= 0 && offset <= (job.size ?? 0))
          'tus_offset': offset,
        'error': failure?.message,
        'error_code': failure?.code,
        if (failure != null) 'failure_count': job.failureCount + 1,
        'retry_at': retryAt?.toUtc().toIso8601String(),
        'native_task_id': null,
        'native_session_id': null,
      },
      where: 'job_id = ? AND attempt_id = ?',
      whereArgs: [jobId, attemptId],
    );
  });

  Future<void> completeBackupJob(
    String jobId,
    String remotePath,
    DateTime now, {
    BackupReceipt? receipt,
  }) => _db.transaction((txn) async {
    final rows = await txn.query(
      'upload_queue',
      where: 'job_id = ?',
      whereArgs: [jobId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final job = BackupJob.fromMap(rows.single);
    if (job.terminal) return;
    if (job.recoverable == true && receipt == null) {
      throw StateError('A recoverable backup needs an authenticated receipt.');
    }
    if (receipt != null) {
      receipt.validate(job);
      if (receipt.state != 'complete') {
        throw StateError('A noncomplete receipt cannot complete a backup.');
      }
    }
    await _completeJob(txn, job, remotePath, now);
  });

  Future<void> _completeJob(
    DatabaseExecutor txn,
    BackupJob job,
    String remotePath,
    DateTime now,
  ) async {
    final stamp = now.toUtc().toIso8601String();
    await txn.insert('backup_ledger', {
      'instance_id': job.instanceId,
      'profile_id': job.profileId,
      'user_id': job.userId,
      'destination_id': job.destinationId,
      'asset_id': job.assetId,
      'job_id': job.jobId,
      'name': job.filename,
      'size': job.size,
      'hash': job.sha256,
      'remote_drive': job.drive,
      'remote_path': remotePath,
      'backed_up_at': stamp,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update(
      'upload_queue',
      {
        'status': BackupJobState.complete.name,
        'tus_offset': job.size,
        'completed_at': stamp,
        'remote_result_path': remotePath,
        'error': null,
        'error_code': null,
        'failure_count': 0,
        'retry_at': null,
        'claim_owner': null,
        'claim_until': null,
      },
      where: 'job_id = ?',
      whereArgs: [job.jobId],
    );
    await _finishReconciledPass(txn, job.profileId, job.destinationId, now);
  }

  Future<void> finishReconciledPass(BackupContext context, DateTime now) =>
      _db.transaction(
        (txn) => _finishReconciledPass(
          txn,
          context.profileId,
          backupDestinationId(context),
          now,
        ),
      );

  Future<void> _finishReconciledPass(
    DatabaseExecutor txn,
    String profileId,
    String destinationId,
    DateTime now,
  ) async {
    final profiles = await txn.query(
      'backup_profile_state',
      columns: ['source_mask'],
      where: 'profile_id = ? AND destination_id = ?',
      whereArgs: [profileId, destinationId],
      limit: 1,
    );
    final sources = profiles.isEmpty
        ? 7
        : (profiles.single['source_mask'] as int? ?? 7);
    final unfinished =
        Sqflite.firstIntValue(
          await txn.rawQuery(
            "SELECT COUNT(*) FROM upload_queue WHERE profile_id = ? "
            "AND destination_id = ? AND job_id IS NOT NULL "
            "AND status NOT IN ('complete','cancelled') AND ("
            "(source_kind = 'photo' AND (? & 1) != 0) OR "
            "(source_kind = 'video' AND (? & 2) != 0) OR "
            "(source_kind = 'contacts' AND (? & 4) != 0))",
            [profileId, destinationId, sources, sources, sources],
          ),
        ) ??
        0;
    if (unfinished != 0) return;
    await txn.rawUpdate(
      'UPDATE backup_profile_state SET last_success_at = ?, '
      'success_scan_id = scan_id, error = NULL, waiting_reason = NULL, '
      'next_retry_at = NULL WHERE profile_id = ? AND destination_id = ? '
      'AND scan_complete = 1 AND scan_error IS NULL AND scan_id IS NOT NULL '
      'AND (success_scan_id IS NULL OR success_scan_id != scan_id)',
      [now.toUtc().toIso8601String(), profileId, destinationId],
    );
  }

  Future<List<BackupJob>> stopBackupProfile(
    String profileId, {
    required bool discard,
    String? leaseOwner,
    DateTime? now,
  }) => _db.transaction((txn) async {
    final rows = await txn.query(
      'upload_queue',
      where:
          "profile_id = ? AND job_id IS NOT NULL "
          "AND status NOT IN ('complete','cancelled')",
      whereArgs: [profileId],
    );
    await txn.delete(
      'backup_locks',
      where: 'lock_key = ?',
      whereArgs: [profileLock(profileId)],
    );
    if (leaseOwner != null) {
      await txn.insert('backup_locks', {
        'lock_key': profileLock(profileId),
        'owner': leaseOwner,
        'expires_at': (now ?? DateTime.now())
            .add(leaseDuration)
            .millisecondsSinceEpoch,
      });
    }
    await txn.update(
      'upload_queue',
      {
        'status': discard
            ? BackupJobState.cancelled.name
            : BackupJobState.paused.name,
        'claim_owner': null,
        'claim_until': null,
        'retry_at': null,
      },
      where:
          "profile_id = ? AND job_id IS NOT NULL "
          "AND status NOT IN ('complete','cancelled')",
      whereArgs: [profileId],
    );
    await txn.update(
      'backup_profile_state',
      {
        'scan_complete': 0,
        'needs_scan': 0,
        'waiting_reason': discard ? 'Backup cancelled.' : 'Backup paused.',
        'next_retry_at': null,
      },
      where: 'profile_id = ?',
      whereArgs: [profileId],
    );
    return rows.map(BackupJob.fromMap).toList();
  });

  Future<int> ownedStagingBytes() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          "SELECT COALESCE(SUM(COALESCE(size, 0) + CASE "
          "WHEN suffix_path IS NOT NULL THEN MAX(0, COALESCE(size, 0) - "
          "COALESCE(suffix_offset, 0)) ELSE 0 END), 0) "
          "FROM upload_queue WHERE job_id IS NOT NULL AND stage_directory IS NOT NULL",
        ),
      ) ??
      0;

  Future<int> stagedBackupJobCount() async =>
      Sqflite.firstIntValue(
        await _db.rawQuery(
          'SELECT COUNT(*) FROM upload_queue WHERE job_id IS NOT NULL '
          'AND stage_directory IS NOT NULL AND local_path != ?',
          [''],
        ),
      ) ??
      0;

  Future<List<BackupJob>> backupCleanupCandidates({int limit = 20}) async {
    final rows = await _db.query(
      'upload_queue',
      where:
          "job_id IS NOT NULL AND stage_directory IS NOT NULL "
          "AND status IN ('complete','cancelled')",
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows.map(BackupJob.fromMap).toList();
  }

  Future<void> markBackupStagingCleaned(String jobId) async {
    await _db.update(
      'upload_queue',
      {'local_path': '', 'stage_directory': null, 'suffix_path': null},
      where: "job_id = ? AND status IN ('complete','cancelled')",
      whereArgs: [jobId],
    );
  }
}
