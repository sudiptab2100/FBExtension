import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/services/backup_policy.dart';

void main() {
  const ready = BackupSettings(enabled: true, driveUuid: 'drive');

  String? reason({
    BackupSettings settings = ready,
    bool active = true,
    bool connected = true,
    bool wifi = true,
    bool charging = true,
    bool manual = false,
  }) => backupPolicyReason(
    settings: settings,
    active: active,
    connected: connected,
    wifi: wifi,
    charging: charging,
    manual: manual,
  );

  test('configured active account on Wi-Fi and power is eligible', () {
    expect(reason(), isNull);
  });

  test('automatic catch-up honors the default charging requirement', () {
    expect(reason(charging: false), contains('charger'));
    expect(
      reason(settings: ready.copyWith(chargingOnly: false), charging: false),
      isNull,
    );
  });

  test(
    'manual backup bypasses charging and auto-enable, not Wi-Fi or identity',
    () {
      expect(
        reason(
          settings: ready.copyWith(enabled: false),
          charging: false,
          manual: true,
        ),
        isNull,
      );
      expect(reason(wifi: false, manual: true), contains('Wi-Fi'));
      expect(reason(active: false, manual: true), contains('another account'));
    },
  );

  test(
    'missing network, destination, sources and disabled auto are explicit',
    () {
      expect(reason(connected: false), contains('network'));
      expect(
        reason(settings: const BackupSettings(enabled: true)),
        contains('destination'),
      );
      expect(
        reason(
          settings: ready.copyWith(
            photos: false,
            videos: false,
            contacts: false,
          ),
        ),
        contains('source'),
      );
      expect(reason(settings: ready.copyWith(enabled: false)), contains('off'));
    },
  );
}
