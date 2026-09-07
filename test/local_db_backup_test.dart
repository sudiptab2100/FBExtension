import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/storage/local_db.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite/sqflite.dart';

class _Transaction extends Mock implements Transaction {}

class _Database extends Mock implements Database {
  _Database(this.txn);
  final _Transaction txn;
  int commits = 0;
  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    final result = await action(txn);
    commits++;
    return result;
  }
}

void main() {
  late _Transaction txn;
  late _Database raw;
  late LocalDb db;
  late BackupJob job;
  final inserted =
      <
        ({
          String table,
          Map<String, Object?> values,
          ConflictAlgorithm? conflict,
        })
      >[];
  final updated = <({String table, Map<String, Object?> values})>[];
  final nativeEvents = <String>{};
  bool leaseExists = true;

  BackupReceipt receipt() => BackupReceipt(
    jobId: job.jobId,
    state: 'complete',
    uploadUrl: '/api/upload/resource',
    size: job.size!,
    sha256: job.sha256!,
    drive: job.drive,
    path: job.remotePath,
    filename: job.filename,
    remotePath: backupJoin(job.remotePath, job.filename),
  );

  setUp(() {
    txn = _Transaction();
    raw = _Database(txn);
    db = LocalDb.fromDatabase(raw);
    inserted.clear();
    updated.clear();
    nativeEvents.clear();
    leaseExists = true;
    job = BackupJob(
      jobId: newBackupId(),
      instanceId: 'instance',
      profileId: '["instance",7]',
      userId: 7,
      destinationId: '["drive","Backup"]',
      assetId: 'asset',
      sourceKind: BackupSourceKind.photo,
      drive: 'drive',
      remotePath: 'Backup/Photos',
      filename: 'photo.jpg',
      localPath: 'owned/source',
      size: 8,
      sha256: 'a' * 64,
      state: BackupJobState.uploading,
      recoverable: true,
      attemptId: 'current-attempt',
      createdAt: DateTime.now().toUtc(),
    );
    when(
      () => txn.query(
        any(),
        columns: any(named: 'columns'),
        where: any(named: 'where'),
        whereArgs: any(named: 'whereArgs'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((invocation) async {
      final table = invocation.positionalArguments.first;
      if (table == 'upload_queue') return [job.toMap()];
      if (table == 'backup_native_events') {
        final id = (invocation.namedArguments[#whereArgs] as List).first;
        return nativeEvents.contains(id)
            ? [
                {'event_id': id},
              ]
            : [];
      }
      if (table == 'backup_locks') {
        return leaseExists
            ? [
                {'owner': 'owner'},
              ]
            : [];
      }
      return [];
    });
    when(
      () => txn.insert(
        any(),
        any(),
        conflictAlgorithm: any(named: 'conflictAlgorithm'),
      ),
    ).thenAnswer((invocation) async {
      final table = invocation.positionalArguments[0] as String;
      final values = Map<String, Object?>.from(
        invocation.positionalArguments[1] as Map,
      );
      inserted.add((
        table: table,
        values: values,
        conflict:
            invocation.namedArguments[#conflictAlgorithm] as ConflictAlgorithm?,
      ));
      if (table == 'backup_native_events') {
        nativeEvents.add(values['event_id'] as String);
      }
      return 1;
    });
    when(
      () => txn.update(
        any(),
        any(),
        where: any(named: 'where'),
        whereArgs: any(named: 'whereArgs'),
      ),
    ).thenAnswer((invocation) async {
      final table = invocation.positionalArguments[0] as String;
      final values = Map<String, Object?>.from(
        invocation.positionalArguments[1] as Map,
      );
      updated.add((table: table, values: values));
      if (table == 'upload_queue') {
        job = BackupJob.fromMap({...job.toMap(), ...values});
      }
      return 1;
    });
    when(() => txn.rawQuery(any(), any())).thenAnswer(
      (_) async => [
        {'count': 0},
      ],
    );
    when(() => txn.rawUpdate(any(), any())).thenAnswer((_) async => 1);
  });

  Future<void> complete({
    String attempt = 'current-attempt',
    BackupReceipt? proof,
  }) => db.recordNativeCompletion(
    eventId: 'event',
    jobId: job.jobId,
    attemptId: attempt,
    statusCode: 204,
    offset: 8,
    cancelled: false,
    errorCode: null,
    completedAt: DateTime.now().toUtc(),
    receipt: proof ?? receipt(),
  );

  test(
    'versioned migrations are additive and preserve unowned historical rows',
    () async {
      final sql = <String>[];
      when(() => raw.execute(any())).thenAnswer((invocation) async {
        sql.add(invocation.positionalArguments.first as String);
      });
      await LocalDb.migrate(raw, 1, LocalDb.schemaVersion);
      expect(LocalDb.schemaVersion, 3);
      expect(
        sql.where((s) => s.startsWith('ALTER TABLE backup_ledger')),
        hasLength(4),
      );
      expect(sql.join('\n'), contains('WHERE user_id IS NULL'));
      expect(sql.join('\n'), contains('WHERE user_id IS NOT NULL'));
      expect(
        sql.join('\n'),
        contains('ON upload_queue(profile_id, destination_id, asset_id)'),
      );
      expect(sql.join('\n'), contains("status != 'cancelled'"));
      expect(
        sql.any((s) => s.contains('DROP TABLE') || s.contains('DELETE FROM')),
        isFalse,
      );
      expect(sql.any((s) => s.contains('UPDATE backup_ledger')), isFalse);
      expect(sql.any((s) => s.contains('CREATE TABLE upload_queue')), isFalse);
      final length = sql.length;
      await LocalDb.migrate(raw, 3, 3);
      expect(sql, hasLength(length));
    },
  );

  test(
    'existing version 2 jobs receive only an additive scan-source column',
    () async {
      final sql = <String>[];
      when(() => raw.execute(any())).thenAnswer((invocation) async {
        sql.add(invocation.positionalArguments.first as String);
      });
      await LocalDb.migrate(raw, 2, 3);
      expect(sql, [
        'ALTER TABLE backup_profile_state ADD COLUMN source_mask '
            'INTEGER NOT NULL DEFAULT 7',
      ]);
    },
  );

  test('receipt completion updates the original queue and scoped ledger in one transaction', () async {
    await complete();
    expect(raw.commits, 1);
    final row = inserted.singleWhere((item) => item.table == 'backup_ledger');
    expect(row.conflict, ConflictAlgorithm.ignore);
    expect(row.values['profile_id'], '["instance",7]');
    expect(row.values['user_id'], 7);
    expect(row.values['destination_id'], '["drive","Backup"]');
    expect(row.values['asset_id'], 'asset');
    expect(row.values['hash'], 'a' * 64);
    expect(job.state, BackupJobState.complete);
    expect(job.offset, 8);
    expect(nativeEvents, {'event'});
  });

  test('native event replay is a no-op, not another ledger insert', () async {
    await complete();
    final proof = receipt();
    await complete(proof: proof);
    expect(
      inserted.where((item) => item.table == 'backup_ledger'),
      hasLength(1),
    );
    expect(
      inserted.where((item) => item.table == 'backup_native_events'),
      hasLength(1),
    );
  });

  test(
    'a stale attempt is journaled but cannot regress a newer attempt',
    () async {
      await complete(attempt: 'old-attempt');
      expect(nativeEvents, {'event'});
      expect(inserted.where((item) => item.table == 'backup_ledger'), isEmpty);
      expect(updated.where((item) => item.table == 'upload_queue'), isEmpty);
      expect(job.state, BackupJobState.uploading);
    },
  );

  test(
    'discarded old-account jobs cannot be credited by late callbacks',
    () async {
      job = BackupJob.fromMap({...job.toMap(), 'status': 'cancelled'});
      await complete();
      expect(nativeEvents, {'event'});
      expect(inserted.where((item) => item.table == 'backup_ledger'), isEmpty);
      expect(job.state, BackupJobState.cancelled);
    },
  );

  test(
    'native HTTP/auth failure never inserts success into the ledger',
    () async {
      await db.recordNativeCompletion(
        eventId: 'event',
        jobId: job.jobId,
        attemptId: job.attemptId!,
        statusCode: 401,
        offset: 0,
        cancelled: false,
        errorCode: null,
        completedAt: DateTime.now().toUtc(),
        failure: BackupFailure(
          'Sign in again.',
          code: 'http_401',
          retryable: false,
        ),
      );
      expect(job.state, BackupJobState.failed);
      expect(job.error, 'Sign in again.');
      expect(job.failureCount, 1);
      expect(inserted.where((item) => item.table == 'backup_ledger'), isEmpty);
    },
  );

  test(
    'revoked cross-isolate leases cannot create another transfer attempt',
    () async {
      leaseExists = false;
      expect(
        await db.startBackupAttempt(
          job: job,
          attemptId: newBackupId(),
          transport: 'native',
          leaseOwner: 'owner',
          generation: 1,
          now: DateTime.now().toUtc(),
        ),
        isFalse,
      );
      expect(inserted, isEmpty);
      expect(updated, isEmpty);
    },
  );

  test('a native attempt is persisted transactionally before a caller can enqueue it', () async {
    final attempt = newBackupId();
    expect(
      await db.startBackupAttempt(
        job: job,
        attemptId: attempt,
        transport: 'native',
        leaseOwner: 'owner',
        generation: 9,
        now: DateTime.now().toUtc(),
      ),
      isTrue,
    );
    expect(raw.commits, 1);
    expect(job.attemptId, attempt);
    expect(job.generation, 9);
    expect(inserted.single.table, 'backup_attempts');
    expect(inserted.single.values['attempt_id'], attempt);
    expect(inserted.single.values['state'], 'submitting');
    expect(inserted.single.values.keys, isNot(contains('headers')));
  });
}
