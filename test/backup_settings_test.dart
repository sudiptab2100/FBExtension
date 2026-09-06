import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';

void main() {
  group('BackupSettings', () {
    test('defaults are safe (disabled, no destination)', () {
      const s = BackupSettings();
      expect(s.enabled, isFalse);
      expect(s.hasDestination, isFalse);
      expect(s.hasSource, isTrue); // photos+videos default on
      expect(s.runnable, isFalse);
    });

    test('runnable requires enabled + destination + a source', () {
      const base = BackupSettings(
        enabled: true,
        driveUuid: 'uuid-1',
        driveLabel: 'Media',
        folder: 'Backup',
      );
      expect(base.runnable, isTrue);

      expect(base.copyWith(enabled: false).runnable, isFalse);
      expect(
        base
            .copyWith(photos: false, videos: false, contacts: false)
            .runnable,
        isFalse,
      );
    });

    test('hasDestination treats empty uuid as unset', () {
      const s = BackupSettings(driveUuid: '');
      expect(s.hasDestination, isFalse);
    });

    test('JSON round-trips all fields', () {
      const s = BackupSettings(
        enabled: true,
        photos: false,
        videos: true,
        contacts: true,
        wifiOnly: false,
        driveUuid: 'uuid-9',
        driveLabel: 'SSD',
        folder: 'Phone/Auto',
      );
      final back = BackupSettings.fromJson(s.toJson());
      expect(back.enabled, s.enabled);
      expect(back.photos, s.photos);
      expect(back.videos, s.videos);
      expect(back.contacts, s.contacts);
      expect(back.wifiOnly, s.wifiOnly);
      expect(back.driveUuid, s.driveUuid);
      expect(back.driveLabel, s.driveLabel);
      expect(back.folder, s.folder);
    });

    test('fromJson tolerates missing keys with defaults', () {
      final s = BackupSettings.fromJson(const {'enabled': true});
      expect(s.enabled, isTrue);
      expect(s.photos, isTrue);
      expect(s.videos, isTrue);
      expect(s.contacts, isFalse);
      expect(s.wifiOnly, isTrue);
      expect(s.folder, 'Backup');
    });
  });
}
