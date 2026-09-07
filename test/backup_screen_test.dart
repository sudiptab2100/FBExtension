import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/theme.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/backup_snapshot.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/features/backup/backup_screen.dart';
import 'package:localdrive_app/state/backup_controller.dart';
import 'package:localdrive_app/state/connection_controller.dart';
import 'package:localdrive_app/state/core_providers.dart';
import 'package:localdrive_app/state/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _settings = BackupSettings(
  enabled: true,
  driveUuid: 'drive',
  driveLabel: 'Backup drive',
);
const _server = LdInstance(
  scheme: 'http',
  host: 'backup.local',
  port: 4820,
  name: 'Mac',
  source: InstanceSource.manual,
);
const _user = AppUser(
  id: 7,
  username: 'alice',
  role: UserRole.user,
  createdAt: '',
  home: 'alice',
  status: UserStatus.active,
);

class _Settings extends BackupSettingsController {
  @override
  BackupSettings build() => _settings;

  @override
  Future<bool> update(
    BackupSettings next, {
    String? expectedInstanceId,
    int? expectedUserId,
  }) async {
    state = next;
    return true;
  }
}

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: SessionStatus.authenticated,
    user: _user,
    token: 'test-only-token',
  );
}

class _Runner extends BackupRunner {
  _Runner(this.initial);
  final BackupRunState initial;

  @override
  BackupRunState build() => initial;
}

Future<void> _pump(WidgetTester tester, BackupRunState run) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.create();
  await tester.binding.setSurfaceSize(const Size(320, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        activeInstanceProvider.overrideWithValue(_server),
        sessionControllerProvider.overrideWith(_Session.new),
        backupSettingsProvider.overrideWith(_Settings.new),
        backupRunnerProvider.overrideWith(() => _Runner(run)),
        backgroundAvailabilityProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const BackupScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'charging-only toggle is visible and enabled under the real theme',
    (tester) async {
      await _pump(tester, const BackupRunState());
      await tester.scrollUntilVisible(
        find.text('Start only while charging'),
        350,
      );
      expect(tester.takeException(), isNull);
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Start only while charging'),
      );
      expect(tile.value, isTrue);
    },
  );

  testWidgets('queued work is not displayed as a completed backup', (
    tester,
  ) async {
    await _pump(
      tester,
      const BackupRunState(queued: 2, waitingReason: 'Waiting for Wi-Fi.'),
    );
    await tester.scrollUntilVisible(find.text('Back up now'), 350);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('2 queued'), findsOneWidget);
    expect(find.text('Waiting for Wi-Fi.'), findsOneWidget);
    expect(find.textContaining('Backup is up to date'), findsNothing);
    expect(find.text('Last successful backup: Never'), findsOneWidget);
  });

  testWidgets('partial failure does not use a success banner', (tester) async {
    await _pump(
      tester,
      const BackupRunState(done: true, uploaded: 2, failed: 1),
    );
    await tester.scrollUntilVisible(find.text('Back up now'), 350);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('could not be backed up'), findsOneWidget);
    expect(find.textContaining('Backup is up to date'), findsNothing);
  });

  testWidgets('a waiting scan cannot reuse a historical success banner', (
    tester,
  ) async {
    await _pump(
      tester,
      BackupRunState.fromSnapshot(
        BackupSnapshot(
          completed: 2,
          lastSuccessAt: DateTime.utc(2026, 9, 1),
          waitingReason: 'Waiting for the charger.',
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Back up now'), 350);
    expect(tester.takeException(), isNull);
    expect(find.text('Waiting for the charger.'), findsOneWidget);
    expect(find.textContaining('Backup is up to date'), findsNothing);
  });
}
