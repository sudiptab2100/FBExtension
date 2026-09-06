import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/app_config.dart';
import 'package:localdrive_app/data/models/drive_info.dart';
import 'package:localdrive_app/data/models/file_entry.dart';
import 'package:localdrive_app/data/models/user.dart';

void main() {
  group('FileEntry', () {
    test('parses a file with mime and mtime', () {
      final e = FileEntry.fromJson({
        'name': 'photo.jpg',
        'path': '/album/photo.jpg',
        'isDir': false,
        'size': 2048,
        'mtimeMs': 1700000000000.0,
        'mime': 'image/jpeg',
      });
      expect(e.name, 'photo.jpg');
      expect(e.isDir, isFalse);
      expect(e.size, 2048);
      expect(e.isImage, isTrue);
      expect(e.isVideo, isFalse);
      expect(e.modified.millisecondsSinceEpoch, 1700000000000);
    });

    test('SearchHit carries the drive', () {
      final h = SearchHit.fromJson({
        'drive': 'DRIVE-1',
        'name': 'notes.txt',
        'path': '/notes.txt',
        'isDir': false,
        'size': 12,
        'mtimeMs': 0,
      });
      expect(h.drive, 'DRIVE-1');
      expect(h.name, 'notes.txt');
    });
  });

  group('DriveInfo', () {
    test('computes used bytes and fraction', () {
      final d = DriveInfo.fromJson({
        'uuid': 'U1',
        'label': 'Backup SSD',
        'online': true,
        'registered': true,
        'external': true,
        'totalBytes': 1000,
        'freeBytes': 250,
        'access': 'granted',
      });
      expect(d.usedBytes, 750);
      expect(d.usedFraction, closeTo(0.75, 1e-9));
      expect(d.isGranted, isTrue);
      expect(d.access, DriveAccess.granted);
    });

    test('missing access parses to null; unknown string to none', () {
      final d = DriveInfo.fromJson({
        'uuid': 'U2',
        'label': 'X',
        'online': false,
        'registered': false,
        'external': false,
      });
      expect(d.access, isNull);
      expect(d.usedBytes, isNull);
      expect(d.usedFraction, isNull);
      expect(driveAccessFromString('weird'), DriveAccess.none);
    });
  });

  group('AppUser', () {
    test('parses role and status', () {
      final admin = AppUser.fromJson({
        'id': 1,
        'username': 'root',
        'role': 'admin',
        'createdAt': '2024-01-01',
        'home': '',
        'status': 'active',
      });
      expect(admin.isAdmin, isTrue);
      expect(admin.isPending, isFalse);

      final pending = AppUser.fromJson({
        'id': 2,
        'username': 'alice',
        'role': 'user',
        'createdAt': '2024-01-02',
        'home': 'alice',
        'status': 'pending',
      });
      expect(pending.isAdmin, isFalse);
      expect(pending.isPending, isTrue);
      expect(pending.home, 'alice');
    });
  });

  group('AppConfig', () {
    test('applies defaults for missing keys', () {
      final c = AppConfig.fromJson({});
      expect(c.port, 4820);
      expect(c.httpsPort, 4843);
      expect(c.shareRootName, 'LocalDrive');
      expect(c.registrationEnabled, isFalse);
    });
  });
}
