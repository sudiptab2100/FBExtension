import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';

void main() {
  const instance = LdInstance(
    scheme: 'http',
    host: 'backup.local',
    port: 4820,
    name: 'Synthetic',
    source: InstanceSource.manual,
  );
  final context = BackupContext(
    instance: instance,
    userId: 7,
    username: 'alice',
    token: 'test-only-token',
    settings: const BackupSettings(driveUuid: 'drive'),
  );
  BackupJob job() => BackupJob(
    jobId: newBackupId(),
    instanceId: instance.id,
    profileId: context.profileId,
    userId: 7,
    destinationId: backupDestinationId(context),
    assetId: 'asset',
    sourceKind: BackupSourceKind.photo,
    drive: 'drive',
    remotePath: 'Backup/Photos',
    filename: 'photo.jpg',
    localPath: 'owned/source',
    size: 8,
    sha256: 'a' * 64,
    createdAt: DateTime.utc(2026, 9, 7),
    generation: 9,
  );

  test('UUIDs are durable-job compatible and unique', () {
    final ids = List.generate(100, (_) => newBackupId());
    expect(ids.every(isBackupId), isTrue);
    expect(ids.toSet(), hasLength(100));
    expect(isBackupId('../outside'), isFalse);
  });

  test('job round trip contains ownership, never credentials', () {
    final original = job();
    final map = original.toMap();
    final restored = BackupJob.fromMap(map);
    expect(restored.toMap(), map);
    expect(restored.generation, 9);
    expect(map.toString(), isNot(contains(context.token)));
    expect(map.keys, isNot(contains('headers')));
    expect(map.keys, isNot(contains('token')));
  });

  test(
    'destination identity normalizes trailing separators but rejects traversal',
    () {
      expect(backupFolder('Backup//Photos/'), 'Backup/Photos');
      expect(backupFolder(''), '');
      for (final invalid in [
        '/Backup',
        '../Backup',
        'Backup/..',
        r'Backup\Photos',
      ]) {
        expect(() => backupFolder(invalid), throwsA(isA<BackupFailure>()));
      }
    },
  );

  test(
    'receipts accept a safe collision filename, not different content or owner',
    () {
      final original = job();
      Map<String, dynamic> receipt() => {
        'jobId': original.jobId,
        'state': 'complete',
        'uploadUrl': '/api/upload/resource',
        'size': 8,
        'sha256': 'a' * 64,
        'drive': 'drive',
        'path': 'Backup/Photos',
        'filename': 'photo-2.jpg',
        'remotePath': 'Backup/Photos/photo-2.jpg',
      };
      expect(
        () => BackupReceipt.fromJson(receipt()).validate(original),
        returnsNormally,
      );
      for (final changed in [
        {'jobId': newBackupId()},
        {'size': 9},
        {'sha256': 'b' * 64},
        {'drive': 'other'},
        {'path': 'Another/Photos'},
        {'filename': '../photo.jpg'},
        {'remotePath': 'another/photo.jpg'},
        {'state': 'unknown'},
      ]) {
        expect(
          () =>
              BackupReceipt.fromJson({...receipt(), ...changed})
                  .validate(original),
          throwsA(isA<BackupFailure>()),
        );
      }
    },
  );
}
