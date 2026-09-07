import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/constants.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/data/models/account.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/data/services/background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

class _Scheduler extends WorkmanagerPlatform {
  int processing = 0;
  int periodic = 0;
  int cancelled = 0;
  Constraints? constraints;
  Duration? delay;
  Future<void> Function()? onRegister;

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    expect(uniqueName, BgTasks.backup);
    cancelled++;
  }

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {
    expect(uniqueName, BgTasks.backup);
    expect(taskName, BgTasks.backup);
    processing++;
    this.constraints = constraints;
    delay = initialDelay;
  }

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
  }) async {
    periodic++;
    this.constraints = constraints;
    delay = frequency;
    expect(existingWorkPolicy, ExistingPeriodicWorkPolicy.update);
    await onRegister?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('localdrive/bg_upload');
  late WorkmanagerPlatform original;
  late _Scheduler scheduler;
  var pending = <String>[BgTasks.backup];

  setUpAll(() {
    Workmanager();
    original = WorkmanagerPlatform.instance;
  });
  setUp(() {
    scheduler = _Scheduler();
    WorkmanagerPlatform.instance = scheduler;
    pending = [BgTasks.backup];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
          expect(call.method, 'environment');
          return {'pendingTaskIdentifiers': pending};
        });
  });
  tearDown(() {
    WorkmanagerPlatform.instance = original;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  test(
    'iOS submits processing, connected network and external power',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await BackgroundService.enableBackup();
      expect(scheduler.processing, 1);
      expect(scheduler.periodic, 0);
      expect(scheduler.cancelled, 1);
      expect(scheduler.constraints?.networkType, NetworkType.connected);
      expect(scheduler.constraints?.requiresCharging, isTrue);
      expect(scheduler.delay, const Duration(hours: 1));
    },
  );

  test(
    'Android stays periodic and retains unmetered/charging constraints',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await BackgroundService.enableBackup();
      expect(scheduler.processing, 0);
      expect(scheduler.periodic, 1);
      expect(scheduler.constraints?.networkType, NetworkType.unmetered);
      expect(scheduler.constraints?.requiresCharging, isTrue);
    },
  );

  test('explicit network/power opt-outs reach Android WorkManager', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await BackgroundService.enableBackup(wifiOnly: false, chargingOnly: false);
    expect(scheduler.constraints?.networkType, NetworkType.connected);
    expect(scheduler.constraints?.requiresCharging, isFalse);
  });

  test('a swallowed iOS submit failure is not reported as scheduled', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    pending = [];
    await expectLater(BackgroundService.enableBackup(), throwsStateError);
  });

  test(
    'logout during scheduling cannot leave an old backup request enabled',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SharedPreferences.setMockInitialValues({});
      final prefs = await Prefs.create();
      await prefs.setActiveInstanceId('server');
      await prefs.setActiveAccount('server', 'alice');
      await prefs.writeAccounts('server', [
        const Account(
          username: 'alice',
          userId: 7,
          role: UserRole.user,
          addedAt: 't',
        ),
      ]);
      await prefs.writeBackupSettings(
        'server',
        7,
        const BackupSettings(enabled: true, driveUuid: 'drive'),
      );
      final started = Completer<void>();
      final resume = Completer<void>();
      scheduler.onRegister = () async {
        started.complete();
        await resume.future;
      };
      final scheduling = BackgroundService.reconcileScheduling(
        includeRefresh: false,
      );
      await started.future;
      await prefs.setBackupAccountBlocked('server', 7, true);
      await prefs.invalidateBackupSession();
      resume.complete();
      await scheduling;
      expect(scheduler.periodic, 1);
      expect(scheduler.cancelled, 1);
    },
  );
}
