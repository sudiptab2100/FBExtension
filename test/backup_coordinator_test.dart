import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/services/background_upload_service.dart';
import 'package:localdrive_app/data/services/backup_coordinator.dart';
import 'package:localdrive_app/data/services/backup_staging.dart';
import 'package:path/path.dart' as p;

import 'support/backup_fakes.dart';

void main() {
  late Directory fixture;
  late File input;
  late MemoryBackupDb db;
  late FakeBackupMedia media;
  late FakeBackupNative native;
  late FakeBackupServer server;
  late BackupContext activeContext;
  bool active = true;
  BackupContext? receiptContext;
  const instance = LdInstance(
    scheme: 'http',
    host: 'backup.local',
    port: 4820,
    name: 'Synthetic',
    source: InstanceSource.manual,
  );

  BackupContext context({
    int userId = 7,
    int generation = 1,
    String folder = 'Backup',
    bool contacts = false,
    bool gallery = true,
  }) => BackupContext(
    instance: instance,
    userId: userId,
    username: userId == 7 ? 'alice' : 'bob',
    token: 'test-token-$userId',
    generation: generation,
    settings: BackupSettings(
      enabled: true,
      driveUuid: 'drive',
      folder: folder,
      photos: gallery,
      videos: false,
      contacts: contacts,
    ),
  );
  BackupCoordinator coordinator() => BackupCoordinator.testing(
    db: db,
    media: media,
    backgroundUploads: native,
    staging: BackupStaging(supportDirectory: () async => fixture),
    tusFactory: server.service,
    isActive: (candidate) async =>
        active &&
        candidate.profileId == activeContext.profileId &&
        candidate.generation == activeContext.generation,
    blockedReason: (_, {manual = false}) async => null,
    receiptContext: (_) async => receiptContext ?? activeContext,
  );

  setUp(() async {
    fixture = Directory(
      p.join(
        Directory.current.path,
        '.dart_tool',
        'backup-core-tests',
        newBackupId(),
      ),
    );
    await fixture.create(recursive: true);
    input = File(p.join(fixture.path, 'original.jpg'));
    await input.writeAsBytes(List.generate(8, (i) => i));
    db = MemoryBackupDb();
    media = FakeBackupMedia(input);
    native = FakeBackupNative(db);
    server = FakeBackupServer();
    activeContext = context();
    active = true;
    receiptContext = null;
  });
  tearDown(() async {
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  test(
    'native enqueue is not success; committed receipt precedes ACK and cleanup',
    () async {
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.error, isNull);
      expect(result.uploaded, 0);
      expect(result.queued, 1);
      final job = db.jobs.values.single;
      expect(job.staged, isTrue);
      expect(job.generation, 1);
      expect(await File(job.localPath).exists(), isTrue);
      final before = await core.snapshot(activeContext);
      expect(before.lastSuccessAt, isNull);
      expect(before.completed, 0);
      expect(before.uploading, 1);
      expect(
        db.trace.indexOf('attempt:${job.attemptId}'),
        lessThan(db.trace.indexOf('enqueue:${job.attemptId}')),
      );

      server.completed.add(job.jobId);
      native.finish(job);
      final eventId = native.completions.single.eventId;
      await core.reconcileCompletions();
      expect(
        db.trace.indexOf('commit:$eventId'),
        lessThan(db.trace.indexOf('ack:$eventId')),
      );
      expect(native.completions, isEmpty);
      expect(await File(job.localPath).exists(), isFalse);
      expect(await input.exists(), isTrue);
      final after = await core.snapshot(activeContext);
      expect(after.completed, 1);
      expect(after.pending, 0);
      expect(after.lastSuccessAt, isNotNull);
    },
  );

  test(
    'a full resumable queue does not masquerade as an unfinished scan',
    () async {
      media = FakeBackupMedia(input, count: 20);
      final core = coordinator();
      await core.runPass(context: activeContext);
      native.tasks.clear();
      await core.reconcileCompletions();
      final ready = await core.snapshot(activeContext);
      expect(ready.queued, 20);
      expect(ready.uploading, 0);
      expect(ready.needsScan, isFalse);
      expect(ready.nextRetryAt, isNull);
      expect(ready.lastSuccessAt, isNull);
      await core.runPass(context: activeContext);
      expect(native.tasks, hasLength(20));
      expect(native.enqueues, hasLength(40));
      expect(server.creates, 20);
    },
  );

  test(
    'paused transfers are exposed separately from source-scan continuation',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      await core.pauseProfile(instance.id, activeContext.userId);
      final paused = await core.snapshot(activeContext);
      expect(paused.paused, 1);
      expect(paused.needsScan, isFalse);
      expect(paused.nextRetryAt, isNull);
    },
  );

  test(
    'snapshot exposes earliest eligible retry without blocking ready jobs',
    () async {
      media = FakeBackupMedia(input, count: 2);
      final core = coordinator();
      await core.runPass(context: activeContext);
      native.tasks.clear();
      final jobs = db.jobs.values.toList();
      final earlier = DateTime.now().toUtc().add(const Duration(minutes: 1));
      final later = earlier.add(const Duration(minutes: 1));
      await db.updateBackupJob(jobs[0].jobId, {
        'status': 'retry',
        'retry_at': later.toIso8601String(),
      });
      await db.updateBackupJob(jobs[1].jobId, {
        'status': 'retry',
        'retry_at': earlier.toIso8601String(),
      });
      final delayed = await core.snapshot(activeContext);
      expect(delayed.needsScan, isFalse);
      expect(delayed.nextRetryAt, earlier);

      await db.updateBackupJob(jobs[0].jobId, {
        'status': 'ready',
        'retry_at': null,
      });
      expect((await core.snapshot(activeContext)).nextRetryAt, isNull);

      final profileGate = later.add(const Duration(minutes: 3));
      await db.updateBackupProfile(activeContext, {
        'next_retry_at': profileGate.toIso8601String(),
      });
      expect((await core.snapshot(activeContext)).nextRetryAt, profileGate);
    },
  );

  test(
    'failed recovery is fenced to the revision that actually attempted it',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      native.tasks.clear();
      activeContext = context(generation: 2);
      server.receiptFailure = BackupFailure(
        'Sign in again.',
        code: 'http_401',
        retryable: false,
        isAuth: true,
      );
      await core.runPass(context: activeContext);
      final failed = await core.snapshot(activeContext);
      expect(db.jobs.values.single.generation, 2);
      expect(failed.failed, 1);
      expect(failed.queued, 0);
      expect(failed.needsScan, isFalse);
    },
  );

  test('native snapshot progress includes the resumed offset and stays within 0..1', () async {
    final core = coordinator();
    await core.runPass(context: activeContext);
    final job = db.jobs.values.single;
    void progress(int sent) {
      native.tasks
        ..clear()
        ..add(
          NativeUploadTask(
            taskId: 1,
            sessionId: 'stable',
            jobId: job.jobId,
            attemptId: job.attemptId!,
            offset: 3,
            bytesSent: sent,
            totalBytes: 8,
          ),
        );
    }

    progress(2);
    expect((await core.snapshot(activeContext)).progress, 0.625);
    progress(100);
    expect((await core.snapshot(activeContext)).progress, 1);
    progress(-10);
    expect((await core.snapshot(activeContext)).progress, 0);
  });

  test('database failure retains native event; ACK failure replays without double credit', () async {
    final core = coordinator();
    await core.runPass(context: activeContext);
    final job = db.jobs.values.single;
    server.completed.add(job.jobId);
    native.finish(job);
    db.failCommit = true;
    await expectLater(core.reconcileCompletions(), throwsStateError);
    expect(native.completions, hasLength(1));
    expect(db.ledger, isEmpty);
    expect(await File(job.localPath).exists(), isTrue);

    db.failCommit = false;
    native.failAck = true;
    await expectLater(
      core.reconcileCompletions(),
      throwsA(isA<PlatformException>()),
    );
    expect(db.ledger, hasLength(1));
    expect(native.completions, hasLength(1));
    expect(await File(job.localPath).exists(), isTrue);
    native.failAck = false;
    await core.reconcileCompletions();
    await core.reconcileCompletions();
    expect(db.ledger, hasLength(1));
    expect(native.completions, isEmpty);
    expect(await File(job.localPath).exists(), isFalse);
  });

  test('lost POST response recovers the same UUID instead of making another resource', () async {
    final core = coordinator();
    server.createFailure = BackupFailure('Connection lost', code: 'network');
    await core.runPass(context: activeContext);
    final original = db.jobs.values.single;
    expect(original.sha256, isNotNull);
    expect(original.tusUrl, isNull);
    expect(server.creates, 1);
    server.createFailure = null;
    await core.runPass(context: activeContext, manual: true);
    expect(server.creates, 1);
    expect(db.jobs.keys, [original.jobId]);
    expect(native.enqueues, hasLength(1));
  });

  test('partial native retry HEADs and hands off a file containing only the suffix', () async {
    final core = coordinator();
    await core.runPass(context: activeContext);
    final first = db.jobs.values.single;
    server.offsets[first.jobId] = 3;
    native.finish(first, status: 503, offset: 3);
    await core.reconcileCompletions();
    expect(db.ledger, isEmpty);
    await core.runPass(context: activeContext, manual: true);
    expect(server.creates, 1);
    expect(native.enqueues, hasLength(2));
    final second = native.enqueues.last;
    expect(second['jobId'], first.jobId);
    expect(second['attemptId'], isNot(first.attemptId));
    expect(second['offset'], 3);
    expect(second['totalBytes'], 8);
    expect(second['body'], [3, 4, 5, 6, 7]);
    expect(second['localPath'], endsWith('suffix-3'));
    expect(
      await File(first.localPath).readAsBytes(),
      List.generate(8, (i) => i),
    );
    expect(db.ledger, isEmpty);
  });

  test(
    'a durable receipt resolves a lost or failed final native response',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final job = db.jobs.values.single;
      server.completed.add(job.jobId);
      native.finish(job, status: 503, offset: 0);
      await core.reconcileCompletions();
      expect(db.ledger, hasLength(1));
      expect((await core.snapshot(activeContext)).completed, 1);
      expect(native.enqueues, hasLength(1));
    },
  );

  test(
    'HTTP success alone does not finish a still-finalizing server job',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final job = db.jobs.values.single;
      server.states[job.jobId] = 'finalizing';
      native.finish(job);
      await core.reconcileCompletions();
      expect(native.completions, isEmpty);
      expect(db.ledger, isEmpty);
      expect(db.jobs[job.jobId]!.state, BackupJobState.reconciling);
      expect((await core.snapshot(activeContext)).lastSuccessAt, isNull);
      expect(await File(job.localPath).exists(), isTrue);
      server.completed.add(job.jobId);
      await core.runPass(context: activeContext, manual: true);
      expect(db.ledger, hasLength(1));
      expect(native.enqueues, hasLength(1));
    },
  );

  test(
    'permanent access failures do not request endless foreground continuation',
    () async {
      server.destinationFailure = BackupFailure(
        'Sign in again.',
        code: 'http_401',
        statusCode: 401,
        retryable: false,
        isAuth: true,
      );
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.error, 'Sign in again.');
      final snapshot = await core.snapshot(activeContext);
      expect(snapshot.needsScan, isFalse);
      expect(snapshot.lastSuccessAt, isNull);
      expect(server.creates, 0);
    },
  );

  test(
    'an old pending native task is never retried because of its age',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final job = db.jobs.values.single;
      db.jobs[job.jobId] = BackupJob.fromMap({
        ...job.toMap(),
        'created_at': '2020-01-01T00:00:00Z',
        'retry_at': '2020-01-01T00:00:00Z',
      });
      await core.runPass(context: activeContext, manual: true);
      expect(native.enqueues, hasLength(1));
      expect(server.creates, 1);
    },
  );

  test(
    'denied source permission is waiting, never a dialog or a successful pass',
    () async {
      media.galleryAllowed = false;
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.waitingReason, contains('photo-library access'));
      expect(media.requests, 0);
      expect(media.exports, 0);
      expect(server.creates, 0);
      expect((await core.snapshot(activeContext)).lastSuccessAt, isNull);
    },
  );

  test(
    'unavailable iCloud media is deferred without advancing last-success',
    () async {
      media.sourceFailure = BackupFailure(
        'Download the iCloud original.',
        code: 'media_cloud',
        waiting: true,
      );
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.waitingReason, contains('iCloud'));
      expect(db.jobs, isEmpty);
      final state = await core.snapshot(activeContext);
      expect(state.lastSuccessAt, isNull);
      expect(state.nextRetryAt, isNotNull);
    },
  );

  test('generation is rechecked after media materialization and before POST/enqueue', () async {
    media.beforeFile = () async => active = false;
    final core = coordinator();
    await core.runPass(context: activeContext);
    expect(db.jobs, isEmpty);
    expect(server.creates, 0);
    expect(native.enqueues, isEmpty);
    expect((await core.snapshot(activeContext)).lastSuccessAt, isNull);
  });

  test('a switch during POST pauses the original account and later recovers its UUID', () async {
    final core = coordinator();
    server.afterCreate = () async => active = false;
    await core.runPass(context: activeContext);
    final job = db.jobs.values.single;
    expect(native.enqueues, isEmpty);
    expect(job.state, BackupJobState.paused);
    expect(db.ledger, isEmpty);
    active = true;
    activeContext = context(generation: 2);
    server.afterCreate = null;
    await core.runPass(context: activeContext, manual: true);
    expect(native.enqueues, hasLength(1));
    expect(server.creates, 1);
    expect(db.jobs.keys, [job.jobId]);
    expect(db.jobs[job.jobId]!.generation, 2);
  });

  test(
    'concurrent foreground and headless passes share a unique lease',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      media.beforeFile = () async {
        if (!started.isCompleted) started.complete();
        await gate.future;
      };
      final first = coordinator().runPass(context: activeContext);
      await started.future;
      final second = await coordinator().runPass(context: activeContext);
      expect(second.waitingReason, contains('already running'));
      gate.complete();
      await first;
      expect(db.jobs, hasLength(1));
      expect(native.enqueues, hasLength(1));
    },
  );

  test(
    'pausing holds the account lease until native cancellation finishes',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final started = Completer<void>();
      final gate = Completer<void>();
      native.beforeCancel = () async {
        started.complete();
        await gate.future;
      };
      final pause = core.pauseProfile(instance.id, activeContext.userId);
      await started.future;
      activeContext = context(generation: 2);
      final concurrent = await coordinator().runPass(
        context: activeContext,
        manual: true,
      );
      expect(concurrent.waitingReason, contains('already running'));
      expect(native.enqueues, hasLength(1));
      gate.complete();
      await pause;
      native.beforeCancel = null;
      await core.runPass(context: activeContext, manual: true);
      expect(native.enqueues, hasLength(2));
      expect(db.jobs, hasLength(1));
      expect(db.jobs.values.single.generation, 2);
    },
  );

  test(
    'an atomically staged source survives a crash before its hash is committed',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final original = db.jobs.values.single;
      native.tasks.clear();
      server.jobs.clear();
      native.enqueues.clear();
      final exports = media.exports;
      db.jobs[original.jobId] = BackupJob.fromMap({
        ...original.toMap(),
        'sha256': null,
        'size': null,
        'tus_url': null,
        'attempt_id': null,
        'status': 'preparing',
      });
      media.sourceFailure = BackupFailure(
        'Original is no longer cached',
        code: 'media_missing',
        waiting: true,
      );
      await core.runPass(context: activeContext, manual: true);
      expect(media.exports, exports);
      expect(db.jobs.values.single.sha256, original.sha256);
      expect(native.enqueues, hasLength(1));
      expect(native.enqueues.single['jobId'], original.jobId);
    },
  );

  test(
    'a late old-account callback cannot credit the selected new account',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final original = activeContext;
      final job = db.jobs.values.single;
      await core.pauseProfile(instance.id, original.userId);
      activeContext = context(userId: 8, generation: 2);
      server.completed.add(job.jobId);
      native.finish(job);
      await core.reconcileCompletions();
      expect(db.ledger, isEmpty);
      expect((await core.snapshot(activeContext)).completed, 0);
      expect(db.jobs[job.jobId]!.state, BackupJobState.paused);

      receiptContext = original;
      await core.reconcileCompletions();
      expect((await core.snapshot(original)).completed, 1);
      expect((await core.snapshot(activeContext)).completed, 0);
    },
  );

  test(
    'discarded jobs keep cancellation tombstones and ignore late success',
    () async {
      final core = coordinator();
      await core.runPass(context: activeContext);
      final job = db.jobs.values.single;
      await core.cancelProfile(
        instance.id,
        activeContext.userId,
        discard: true,
      );
      expect(db.jobs[job.jobId]!.state, BackupJobState.cancelled);
      server.completed.add(job.jobId);
      native.finish(job);
      await core.reconcileCompletions();
      expect(db.ledger, isEmpty);
      expect(db.jobs[job.jobId]!.state, BackupJobState.cancelled);
      expect(native.completions, isEmpty);
    },
  );

  test(
    'gallery preparation is capped at 20 jobs, with a durable scan cursor',
    () async {
      media = FakeBackupMedia(input, count: 90);
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.queued, 20);
      expect(media.exports, 20);
      expect(media.pageCalls, 1);
      expect(db.jobs, hasLength(20));
      expect((await db.backupProfile(activeContext))['scan_index'], 20);
      expect((await core.snapshot(activeContext)).needsScan, isTrue);
      await core.runPass(context: activeContext, manual: true);
      expect(media.exports, 20);
      expect(native.enqueues, hasLength(20));
    },
  );

  test('bounded batches continue from the durable cursor without premature pass success', () async {
    media = FakeBackupMedia(input, count: 25);
    final core = coordinator();
    await core.runPass(context: activeContext, manual: true);
    expect(media.exports, 20);
    for (final job in db.jobs.values.toList()) {
      server.completed.add(job.jobId);
      native.finish(job);
    }
    await core.reconcileCompletions();
    final remaining = await core.snapshot(activeContext);
    expect(remaining.pending, 0);
    expect(remaining.needsScan, isTrue);
    expect(remaining.lastSuccessAt, isNull);

    await core.runPass(context: activeContext, manual: true);
    expect(media.exports, 25);
    expect(db.jobs, hasLength(25));
    expect(native.tasks, hasLength(5));
    for (final job in db.jobs.values.where((job) => !job.terminal).toList()) {
      server.completed.add(job.jobId);
      native.finish(job);
    }
    await core.reconcileCompletions();
    final finished = await core.snapshot(activeContext);
    expect(finished.completed, 25);
    expect(finished.pending, 0);
    expect(finished.needsScan, isFalse);
    expect(finished.lastSuccessAt, isNotNull);
  });

  test('disabled-source jobs do not consume the current batch or block its success', () async {
    media = FakeBackupMedia(input, count: 20);
    final core = coordinator();
    final photosContext = activeContext;
    await core.runPass(context: activeContext);
    expect(db.jobs, hasLength(20));
    await core.pauseProfile(instance.id, activeContext.userId);
    activeContext = context(generation: 2, gallery: false, contacts: true);
    final before = await core.snapshot(activeContext);
    expect(before.pending, 0);
    expect(before.needsScan, isTrue);
    expect((await core.snapshot(photosContext)).paused, 20);

    await core.runPass(context: activeContext);
    expect(media.contactsExports, 1);
    expect(native.tasks, hasLength(1));
    final contacts = db.jobs.values.singleWhere(
      (job) => job.sourceKind == BackupSourceKind.contacts,
    );
    expect(contacts.state, BackupJobState.uploading);
    server.completed.add(contacts.jobId);
    native.finish(contacts);
    await core.reconcileCompletions();
    final after = await core.snapshot(activeContext);
    expect(after.pending, 0);
    expect(after.needsScan, isFalse);
    expect(after.lastSuccessAt, isNotNull);
    expect(
      db.jobs.values.where(
        (job) =>
            job.sourceKind == BackupSourceKind.photo &&
            job.state == BackupJobState.paused,
      ),
      hasLength(20),
    );
  });

  test(
    'Android retains foreground tus and invokes no native iOS methods',
    () async {
      native = FakeBackupNative(db, supported: false);
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.error, isNull);
      expect(result.uploaded, 1);
      expect(server.foregroundUploads, 1);
      expect(native.calls, 0);
      expect((await core.snapshot(activeContext)).lastSuccessAt, isNotNull);
    },
  );

  test('legacy servers require explicit manual foreground upload, without native fallback', () async {
    server.recoverable = false;
    final core = coordinator();
    final automatic = await core.runPass(context: activeContext);
    expect(automatic.waitingReason, contains('Update'));
    expect(server.creates, 0);
    expect((await core.snapshot(activeContext)).lastSuccessAt, isNull);
    final manual = await core.runPass(context: activeContext, manual: true);
    expect(manual.uploaded, 1);
    expect(server.foregroundUploads, 1);
    expect(native.enqueues, isEmpty);
    expect(db.jobs.values.single.recoverable, isFalse);
  });

  test(
    'a missing native bridge never silently falls back to foreground',
    () async {
      native.failEnqueue = true;
      final core = coordinator();
      final result = await core.runPass(context: activeContext);
      expect(result.error, isNotNull);
      expect(server.foregroundUploads, 0);
      expect(db.ledger, isEmpty);
      expect((await core.snapshot(activeContext)).lastSuccessAt, isNull);
    },
  );

  test('daily contacts use the same durable native pipeline and destination ledger', () async {
    activeContext = context(gallery: false, contacts: true);
    final core = coordinator();
    await core.runPass(context: activeContext);
    final first = db.jobs.values.single;
    expect(first.sourceKind, BackupSourceKind.contacts);
    expect(first.remotePath, 'Backup/Contacts');
    expect(first.assetId, startsWith('contacts-'));
    expect(native.enqueues, hasLength(1));
    expect(media.requests, 0);
    server.completed.add(first.jobId);
    native.finish(first);
    await core.reconcileCompletions();
    await core.runPass(context: activeContext, manual: true);
    expect(media.contactsExports, 1);
    expect(db.ledger, hasLength(1));

    activeContext = context(
      generation: 2,
      folder: 'Another',
      gallery: false,
      contacts: true,
    );
    await core.runPass(context: activeContext, manual: true);
    expect(db.jobs, hasLength(2));
    expect(db.jobs.values.last.remotePath, 'Another/Contacts');
    expect((await core.snapshot(activeContext)).completed, 0);
  });
}
