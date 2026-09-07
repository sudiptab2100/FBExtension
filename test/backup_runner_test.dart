import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/constants.dart';
import 'package:localdrive_app/core/storage/backup_keys.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/data/models/account.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/backup_snapshot.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/data/services/backup_coordinator.dart';
import 'package:localdrive_app/data/services/backup_engine.dart';
import 'package:localdrive_app/state/backup_controller.dart';
import 'package:localdrive_app/state/connection_controller.dart';
import 'package:localdrive_app/state/core_providers.dart';
import 'package:localdrive_app/state/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = LdInstance(
  scheme: 'http',
  host: 'backup.local',
  port: 4820,
  name: 'Synthetic server',
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

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: SessionStatus.authenticated,
    user: _user,
    token: 'test-only-token',
  );
}

class _Coordinator extends Fake implements BackupCoordinator {
  _Coordinator(this.status);
  final BackupSnapshot status;
  int passes = 0;

  @override
  Future<void> reconcileCompletions() async {}

  @override
  Future<BackupSnapshot> snapshot(BackupContext context) async => status;

  @override
  Future<BackupResult> runPass({
    required BackupContext context,
    bool manual = false,
    BackupProgress? onProgress,
  }) async {
    passes++;
    return BackupResult(queued: status.pending);
  }
}

Future<_Coordinator> _catchUp(BackupSnapshot snapshot) async {
  SharedPreferences.setMockInitialValues({
    StoreKeys.savedInstances: jsonEncode([_server.toJson()]),
    StoreKeys.activeInstanceId: _server.id,
    '${StoreKeys.activeAccountPrefix}${_server.id}': _user.username,
    '${StoreKeys.accountsPrefix}${_server.id}': jsonEncode([
      const Account(
        username: 'alice',
        userId: 7,
        role: UserRole.user,
        addedAt: '',
      ).toJson(),
    ]),
  });
  final prefs = await Prefs.create();
  await prefs.writeBackupSettings(
    _server.id,
    _user.id,
    const BackupSettings(
      enabled: true,
      driveUuid: 'drive',
      chargingOnly: false,
    ),
  );
  await prefs.setBackupAttempt(
    backupProfileKey(_server.id, _user.id),
    DateTime.now().toUtc(),
  );
  final coordinator = _Coordinator(snapshot);
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      activeInstanceProvider.overrideWithValue(_server),
      sessionControllerProvider.overrideWith(_Session.new),
      backupCoordinatorProvider.overrideWith((_) async => coordinator),
    ],
  );
  addTearDown(container.dispose);
  await container.read(backupRunnerProvider.notifier).catchUp();
  expect(container.read(backupRunnerProvider).error, isNull);
  expect(container.read(backupRunnerProvider).waitingReason, isNull);
  return coordinator;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
  });
  tearDown(() => messenger.setMockMethodCallHandler(connectivity, null));

  test(
    'a full queued batch resumes despite the recent-attempt debounce',
    () async {
      final coordinator = await _catchUp(const BackupSnapshot(queued: 25));
      expect(coordinator.passes, 1);
    },
  );

  test('a full paused batch resumes without a new manual tap', () async {
    final coordinator = await _catchUp(const BackupSnapshot(paused: 25));
    expect(coordinator.passes, 1);
  });

  test('bounded preparation belongs to the durable coordinator', () async {
    final coordinator = await _catchUp(
      const BackupSnapshot(uploading: 20, needsScan: true),
    );
    expect(coordinator.passes, 1);
  });

  test('already active transfers do not start redundant preparation', () async {
    final coordinator = await _catchUp(const BackupSnapshot(uploading: 20));
    expect(coordinator.passes, 0);
  });

  test('a finished scan still honors the recent-attempt debounce', () async {
    final coordinator = await _catchUp(const BackupSnapshot());
    expect(coordinator.passes, 0);
  });

  test('queued recovery still honors a future retry time', () async {
    final coordinator = await _catchUp(
      BackupSnapshot(
        queued: 25,
        nextRetryAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
      ),
    );
    expect(coordinator.passes, 0);
  });
}
