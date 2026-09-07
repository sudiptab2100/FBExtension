import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/services/media_service.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const contactsChannel = MethodChannel('flutter_contacts');
  const photosChannel = MethodChannel('com.fluttercandies/photo_manager');
  const media = MediaService();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory directory;
  var permission = 'granted';
  var photoPermission = 3;

  setUp(() async {
    calls.clear();
    permission = 'granted';
    photoPermission = 3;
    directory = Directory(
      p.join(
        Directory.current.path,
        '.dart_tool',
        'backup-core-tests',
        newBackupId(),
      ),
    );
    await directory.create(recursive: true);
    messenger.setMockMethodCallHandler(contactsChannel, (call) async {
      calls.add(call);
      if (call.method == 'permissions.check') return permission;
      if (call.method == 'crud.getAll') {
        expect((call.arguments as Map)['properties'], isEmpty);
        return List.generate(12, (i) => {'id': 'contact-$i'});
      }
      if (call.method == 'crud.get') {
        final id = (call.arguments as Map)['id'];
        return {
          'id': id,
          'displayName': id,
          'name': {'first': id},
        };
      }
      throw StateError('Unexpected contacts API: ${call.method}');
    });
    messenger.setMockMethodCallHandler(photosChannel, (call) async {
      calls.add(call);
      if (call.method == 'getPermissionState') return photoPermission;
      if (call.method == 'isLocallyAvailable') return false;
      throw StateError('Unexpected photo API: ${call.method}');
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(contactsChannel, null);
    messenger.setMockMethodCallHandler(photosChannel, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('headless permission checks never request a dialog and respect limited access', () async {
    expect(await media.hasGalleryAccess(photos: true, videos: false), isTrue);
    expect(await media.hasContactsAccess(), isTrue);
    photoPermission = 4;
    permission = 'limited';
    expect(await media.hasGalleryAccess(), isTrue);
    expect(await media.hasContactsAccess(), isTrue);
    photoPermission = 2;
    permission = 'denied';
    expect(await media.hasGalleryAccess(), isFalse);
    expect(await media.hasContactsAccess(), isFalse);
    expect(calls.map((call) => call.method).toSet(), {
      'getPermissionState',
      'permissions.check',
    });
  });

  test('iCloud-only assets do not begin a media download', () async {
    final asset = AssetEntity(id: 'cloud', typeInt: 1, width: 10, height: 10);
    await expectLater(
      media.backupFile(asset),
      throwsA(
        isA<BackupFailure>().having(
          (error) => error.code,
          'code',
          'media_cloud',
        ),
      ),
    );
    expect(calls.map((call) => call.method), ['isLocallyAvailable']);
  }, skip: !Platform.isMacOS && !Platform.isIOS);

  test('contacts export checkpoints recover without duplicate vCards or whole-property loading', () async {
    var checkpoints = 0;
    await expectLater(
      media.exportBackupContacts(
        directory,
        checkpoint: () async {
          if (++checkpoints == 12) {
            throw StateError('Processing window expired');
          }
        },
      ),
      throwsStateError,
    );
    final checkpoint = jsonDecode(
      await File(p.join(directory.path, 'contacts.cursor')).readAsString(),
    ) as Map;
    expect(checkpoint['index'], 10);
    final result = await media.exportBackupContacts(
      directory,
      checkpoint: () async {},
    );
    expect(result, 12);
    final vcard = await File(p.join(directory.path, 'contacts.export'))
        .readAsString();
    expect('BEGIN:VCARD'.allMatches(vcard), hasLength(12));
    expect('END:VCARD'.allMatches(vcard), hasLength(12));
    expect(calls.where((call) => call.method == 'crud.getAll'), hasLength(1));
    expect(calls.where((call) => call.method == 'crud.get'), hasLength(13));
    expect(
      calls.any((call) => call.method.startsWith('permissions.request')),
      isFalse,
    );
  });

  test(
    'contacts respect the available staging allowance without fake completion',
    () async {
      await expectLater(
        media.exportBackupContacts(
          directory,
          checkpoint: () async {},
          maximumBytes: 1,
        ),
        throwsA(
          isA<BackupFailure>().having(
            (error) => error.code,
            'code',
            'staging_budget',
          ),
        ),
      );
      expect(await File(p.join(directory.path, 'contacts.export')).length(), 0);
      expect(
        await media.exportBackupContacts(directory, checkpoint: () async {}),
        12,
      );
    },
  );
}
