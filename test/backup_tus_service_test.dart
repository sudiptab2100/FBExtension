import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/services/backup_tus_service.dart';
import 'package:path/path.dart' as p;

void main() {
  const instance = LdInstance(
    scheme: 'https',
    host: 'backup.local',
    port: 4843,
    name: 'Synthetic',
    source: InstanceSource.manual,
  );
  const context = BackupContext(
    instance: instance,
    userId: 7,
    username: 'alice',
    token: 'test-only-token',
    settings: BackupSettings(driveUuid: 'drive'),
  );
  BackupJob job({String path = 'owned/source', int offset = 0}) => BackupJob(
    jobId: '89ab0123-4567-489a-9bcd-0123456789ab',
    instanceId: instance.id,
    profileId: context.profileId,
    userId: 7,
    destinationId: backupDestinationId(context),
    assetId: 'photo',
    sourceKind: BackupSourceKind.photo,
    drive: 'drive',
    remotePath: 'Backup/Photos',
    filename: 'photo.jpg',
    createdAt: DateTime.utc(2026, 9, 7),
    localPath: path,
    size: 8,
    sha256: 'a' * 64,
    recoverable: true,
    offset: offset,
    tusUrl: 'https://backup.local:4843/api/upload/resource',
  );
  Map<String, dynamic> receipt() => {
    'jobId': job().jobId,
    'state': 'complete',
    'uploadUrl': '/api/upload/resource',
    'size': 8,
    'sha256': 'a' * 64,
    'drive': 'drive',
    'path': 'Backup/Photos',
    'filename': 'photo-2.jpg',
    'remotePath': 'Backup/Photos/photo-2.jpg',
  };

  test(
    'POST persists immutable recovery metadata and refuses redirects',
    () async {
      final requests = <http.Request>[];
      final service = BackupTusService(
        context,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            '',
            201,
            headers: {'location': '/api/upload/resource'},
          );
        }),
      );
      addTearDown(service.close);
      final result = await service.create(job(), recoverable: true);
      expect(result.toString(), job().tusUrl);
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/upload');
      expect(request.headers['Cookie'], 'ld_view=user');
      expect(request.headers['Authorization'], 'Bearer test-only-token');
      expect(request.headers['Upload-Length'], '8');
      expect(request.followRedirects, isFalse);
      final values = <String, String>{};
      for (final field in request.headers['Upload-Metadata']!.split(',')) {
        final separator = field.indexOf(' ');
        values[field.substring(0, separator)] = utf8.decode(
          base64Decode(field.substring(separator + 1)),
        );
      }
      expect(values, {
        'filename': 'photo.jpg',
        'drive': 'drive',
        'path': 'Backup/Photos',
        'backupJobId': job().jobId,
        'backupSha256': 'a' * 64,
      });
    },
  );

  test(
    'duplicate create is recovered through an authenticated complete receipt',
    () async {
      final methods = <String>[];
      final service = BackupTusService(
        context,
        client: MockClient((request) async {
          methods.add(request.method);
          expect(request.headers['Cookie'], 'ld_view=user');
          return request.method == 'POST'
              ? http.Response('', 409)
              : http.Response(jsonEncode(receipt()), 200);
        }),
      );
      addTearDown(service.close);
      expect(await service.create(job(), recoverable: true), isNull);
      final recovered = await service.receipt(job());
      expect(recovered!.state, 'complete');
      expect(recovered.remotePath, 'Backup/Photos/photo-2.jpg');
      expect(methods, ['POST', 'GET']);
    },
  );

  test('HEAD validates actual offset and immutable upload length', () async {
    var length = 8;
    final service = BackupTusService(
      context,
      client: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'upload-offset': '3', 'upload-length': '$length'},
        ),
      ),
    );
    addTearDown(service.close);
    expect(await service.head(job(), Uri.parse(job().tusUrl!)), 3);
    length = 9;
    await expectLater(
      service.head(job(), Uri.parse(job().tusUrl!)),
      throwsA(
        isA<BackupFailure>().having((e) => e.code, 'code', 'upload_offset'),
      ),
    );
  });

  test('missing upload and unknown owner receipt are not success', () async {
    final service = BackupTusService(
      context,
      client: MockClient((_) async => http.Response('', 404)),
    );
    addTearDown(service.close);
    expect(await service.receipt(job()), isNull);
    expect(await service.head(job(), Uri.parse(job().tusUrl!)), isNull);
  });

  test('receipt identity mismatch never credits same-name content', () async {
    final service = BackupTusService(
      context,
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({...receipt(), 'sha256': 'b' * 64}), 200),
      ),
    );
    addTearDown(service.close);
    await expectLater(
      service.receipt(job()),
      throwsA(
        isA<BackupFailure>().having((e) => e.code, 'code', 'receipt_mismatch'),
      ),
    );
  });

  test('legacy creation explicitly omits recoverability metadata', () async {
    final service = BackupTusService(
      context,
      client: MockClient((request) async {
        expect(
          request.headers['Upload-Metadata'],
          isNot(contains('backupJobId')),
        );
        expect(
          request.headers['Upload-Metadata'],
          isNot(contains('backupSha256')),
        );
        return http.Response(
          '',
          201,
          headers: {'location': '/api/upload/legacy'},
        );
      }),
    );
    addTearDown(service.close);
    expect(
      (await service.create(job(), recoverable: false))!.path,
      '/api/upload/legacy',
    );
  });

  test('unsafe and redirected upload URLs are refused', () {
    final service = BackupTusService(
      context,
      client: MockClient((_) async => http.Response('', 500)),
    );
    addTearDown(service.close);
    for (final unsafe in [
      'http://backup.local:4843/api/upload/id',
      'https://other.local:4843/api/upload/id',
      'https://name@backup.local:4843/api/upload/id',
      '/api/upload/id?token=not-a-real-token',
      '/api/upload/a%2fb',
      '/api/another/id',
      '/api/upload/id#fragment',
    ]) {
      expect(() => service.uploadUrl(unsafe), throwsA(isA<BackupFailure>()));
    }
  });

  test('auth, drive and transport errors remain actionable', () async {
    var status = 401;
    final service = BackupTusService(
      context,
      client: MockClient((_) async => http.Response('', status)),
    );
    addTearDown(service.close);
    await expectLater(
      service.receipt(job()),
      throwsA(isA<BackupFailure>().having((e) => e.isAuth, 'auth', isTrue)),
    );
    status = 503;
    await expectLater(
      service.receipt(job()),
      throwsA(isA<BackupFailure>().having((e) => e.retryable, 'retry', isTrue)),
    );
    status = 403;
    await expectLater(
      service.receipt(job()),
      throwsA(
        isA<BackupFailure>().having((e) => e.retryable, 'retry', isFalse),
      ),
    );
  });

  test(
    'Android tus chunks resume the saved URL and persist acknowledged offsets',
    () async {
      final dir = Directory(
        p.join(
          Directory.current.path,
          '.dart_tool',
          'backup-core-tests',
          newBackupId(),
        ),
      );
      await dir.create(recursive: true);
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'source'));
      await file.writeAsBytes(List.generate(8, (i) => i));
      final methods = <String>[];
      final offsets = <int>[];
      var checks = 0;
      final service = BackupTusService(
        context,
        client: MockClient((request) async {
          methods.add(request.method);
          expect(request.url.path, '/api/upload/resource');
          expect(request.followRedirects, isFalse);
          if (request.method == 'HEAD') {
            return http.Response(
              '',
              200,
              headers: {'upload-offset': '3', 'upload-length': '8'},
            );
          }
          expect(request.method, 'PATCH');
          expect(request.headers['Upload-Offset'], '3');
          expect(request.bodyBytes, [3, 4, 5, 6, 7]);
          return http.Response('', 204, headers: {'upload-offset': '8'});
        }),
      );
      addTearDown(service.close);
      expect(
        await service.uploadForeground(
          job: job(path: file.path, offset: 3),
          beforeTransfer: () async => checks++,
          onOffset: (offset) async => offsets.add(offset),
        ),
        isTrue,
      );
      expect(methods, ['HEAD', 'PATCH']);
      expect(checks, 2);
      expect(offsets, [8]);
    },
  );
}
