import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/services/backup_staging.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory fixture;
  late BackupStaging staging;
  late File input;
  const bytes = [0, 1, 2, 3, 4, 5, 6, 7];

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
    staging = BackupStaging(supportDirectory: () async => fixture);
    input = File(p.join(fixture.path, 'original'));
    await input.writeAsBytes(bytes);
  });
  tearDown(() async {
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  BackupJob job(String id, StagedBackupSource staged) => BackupJob(
    jobId: id,
    instanceId: 'instance',
    profileId: 'profile',
    userId: 7,
    destinationId: 'destination',
    assetId: 'asset',
    sourceKind: BackupSourceKind.photo,
    drive: 'drive',
    remotePath: 'Photos',
    filename: 'original',
    createdAt: DateTime.now(),
    stageDirectory: staged.directory,
    localPath: staged.path,
    size: staged.size,
    sha256: staged.sha256,
  );

  test(
    'staging hashes content and creates only the remaining native suffix',
    () async {
      final id = newBackupId();
      var checks = 0;
      final staged = await staging.copySource(
        jobId: id,
        source: input,
        checkpoint: () async => checks++,
      );
      final original = job(id, staged);
      expect(staged.size, bytes.length);
      expect(staged.sha256, sha256.convert(bytes).toString());
      expect(staged.path, endsWith('$id/source'));
      expect(checks, greaterThan(0));
      final suffix = await staging.suffix(original, 3, checkpoint: () async {});
      expect(await File(suffix).readAsBytes(), bytes.sublist(3));
      expect(await input.readAsBytes(), bytes);
      expect(await File(staged.path).readAsBytes(), bytes);
      await staging.cleanup(original);
      expect(await Directory(staged.directory).exists(), isFalse);
      expect(await input.exists(), isTrue);
    },
  );

  test(
    'bounded copy removes an incomplete owned file, never the input',
    () async {
      final id = newBackupId();
      await expectLater(
        staging.copySource(
          jobId: id,
          source: input,
          checkpoint: () async {},
          maximumBytes: 3,
        ),
        throwsA(
          isA<BackupFailure>().having((e) => e.code, 'code', 'staging_budget'),
        ),
      );
      final dir = await staging.directoryFor(id);
      expect(await dir.list().toList(), isEmpty);
      expect(await input.readAsBytes(), bytes);
    },
  );

  test(
    'account invalidation interrupts a copy without leaving a partial',
    () async {
      final id = newBackupId();
      await expectLater(
        staging.copySource(
          jobId: id,
          source: input,
          checkpoint: () async => throw StateError('Account changed'),
        ),
        throwsStateError,
      );
      expect(await (await staging.directoryFor(id)).list().toList(), isEmpty);
    },
  );

  test('cleanup refuses unowned or linked paths', () async {
    final id = newBackupId();
    final unsafe = job(
      id,
      StagedBackupSource(
        path: input.path,
        directory: fixture.path,
        size: 8,
        sha256: 'a' * 64,
      ),
    );
    await expectLater(staging.cleanup(unsafe), throwsStateError);
    expect(await input.exists(), isTrue);
    final root = await staging.root();
    final link = Link(p.join(root.path, id));
    await link.create(fixture.path);
    await expectLater(staging.directoryFor(id), throwsStateError);
    await link.delete();
  });

  test(
    'modified staged bytes are not silently sent with an old hash',
    () async {
      final id = newBackupId();
      final staged = await staging.copySource(
        jobId: id,
        source: input,
        checkpoint: () async {},
      );
      await File(staged.path).writeAsBytes(bytes.reversed.toList());
      await expectLater(
        staging.verifySource(job(id, staged), checkpoint: () async {}),
        throwsA(
          isA<BackupFailure>().having((e) => e.code, 'code', 'source_changed'),
        ),
      );
    },
  );
}
