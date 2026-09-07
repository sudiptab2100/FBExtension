import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localdrive_app/app.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/routing/router.dart';
import 'package:localdrive_app/state/backup_controller.dart';
import 'package:localdrive_app/state/connection_controller.dart';
import 'package:localdrive_app/state/core_providers.dart';
import 'package:localdrive_app/state/live_events.dart';
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
  _Session(this.authenticated);
  final bool authenticated;

  @override
  SessionState build() => authenticated
      ? const SessionState(
          status: SessionStatus.authenticated,
          user: _user,
          token: 'test-only-token',
        )
      : const SessionState(status: SessionStatus.unauthenticated);
}

class _Settings extends BackupSettingsController {
  @override
  BackupSettings build() => const BackupSettings();
}

class _LiveEvents extends LiveEventsController {
  @override
  bool build() => false;
}

class _Runner extends BackupRunner {
  _Runner({this.firstRefresh});
  final Completer<void>? firstRefresh;
  final calls = <String>[];
  int refreshes = 0;

  @override
  BackupRunState build() => const BackupRunState();

  @override
  Future<void> refresh() async {
    calls.add('refresh');
    if (++refreshes == 1) await firstRefresh?.future;
  }

  @override
  Future<void> catchUp({bool force = false}) async {
    calls.add('catch-up:$force');
  }

  @override
  void stopForegroundContinuation() => calls.add('stop-continuation');
}

Future<void> _pump(
  WidgetTester tester,
  _Runner runner, {
  bool authenticated = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await Prefs.create();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  const channels = [
    MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    MethodChannel('dev.fluttercommunity.plus/charging'),
  ];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final channel in channels) {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  }
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const Scaffold())],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    router.dispose();
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        activeInstanceProvider.overrideWithValue(_server),
        sessionControllerProvider.overrideWith(() => _Session(authenticated)),
        backupSettingsProvider.overrideWith(_Settings.new),
        backupRunnerProvider.overrideWith(() => runner),
        liveEventsProvider.overrideWith(_LiveEvents.new),
        routerProvider.overrideWithValue(router),
      ],
      child: const LocalDriveApp(),
    ),
  );
  await tester.pump();
}

void main() {
  final platform = TargetPlatformVariant.only(TargetPlatform.macOS);
  testWidgets('launch reconciles before a forced catch-up', (tester) async {
    final runner = _Runner();
    await _pump(tester, runner);
    expect(runner.calls, ['refresh', 'catch-up:true']);
  }, variant: platform);

  testWidgets('resume during reconciliation preserves a fresh catch-up', (
    tester,
  ) async {
    final gate = Completer<void>();
    final runner = _Runner(firstRefresh: gate);
    await _pump(tester, runner);
    expect(runner.calls, ['refresh']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(runner.calls, [
      'refresh',
      'stop-continuation',
      'catch-up:true',
      'refresh',
      'catch-up:true',
    ]);
  }, variant: platform);

  testWidgets('signed-out launch still reconciles but never prepares work', (
    tester,
  ) async {
    final runner = _Runner();
    await _pump(tester, runner, authenticated: false);
    expect(runner.calls, ['refresh']);
  }, variant: platform);
}
