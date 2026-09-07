import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/theme.dart';
import 'data/models/backup_settings.dart';
import 'data/services/background_service.dart';
import 'data/services/backup_errors.dart';
import 'routing/router.dart';
import 'state/backup_controller.dart';
import 'state/core_providers.dart';
import 'state/live_events.dart';
import 'state/session_controller.dart';
import 'state/settings_controller.dart';

/// Root widget: wires the router, theme, and theme-mode into [MaterialApp].
class LocalDriveApp extends ConsumerStatefulWidget {
  const LocalDriveApp({super.key});

  @override
  ConsumerState<LocalDriveApp> createState() => _LocalDriveAppState();
}

class _LocalDriveAppState extends ConsumerState<LocalDriveApp>
    with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<BatteryState>? _battery;
  Timer? _ticker;
  bool _foreground = false;
  bool _evaluating = false;
  bool _evaluateAgain = false;
  bool _forceEvaluation = false;
  bool _scheduling = false;
  bool _scheduleAgain = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _connectivity = Connectivity().onConnectivityChanged.listen(
      (_) => _scheduleEvaluation(force: true),
      onError: _environmentError,
    );
    _battery = Battery().onBatteryStateChanged.listen(
      (_) => _scheduleEvaluation(force: true),
      onError: _environmentError,
    );
    if (_foreground) _startTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_foreground) return;
      unawaited(_reschedule());
      unawaited(_evaluate(force: true));
    });
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_evaluate()),
    );
  }

  void _environmentError(Object error) {
    if (!mounted) return;
    ref
        .read(backupRunnerProvider.notifier)
        .reportError(backupFailureMessage(error));
  }

  void _scheduleEvaluation({bool force = false}) {
    if (!_foreground) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_evaluate(force: force));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _evaluate({bool force = false}) async {
    if (!mounted || !_foreground) return;
    _forceEvaluation = _forceEvaluation || force;
    if (_evaluating) {
      _evaluateAgain = true;
      return;
    }
    _evaluating = true;
    try {
      do {
        _evaluateAgain = false;
        final forcePass = _forceEvaluation;
        _forceEvaluation = false;
        await ref.read(prefsProvider).reload();
        if (!mounted || !_foreground) return;
        final runner = ref.read(backupRunnerProvider.notifier);
        await runner.refresh();
        if (!mounted || !_foreground) return;
        if (ref.read(sessionControllerProvider).isAuthenticated) {
          await runner.catchUp(force: forcePass);
        }
      } while (_evaluateAgain && mounted && _foreground);
    } catch (error) {
      _environmentError(error);
    } finally {
      _evaluating = false;
    }
  }

  Future<void> _reschedule() async {
    if (_scheduling) {
      _scheduleAgain = true;
      return;
    }
    _scheduling = true;
    try {
      do {
        _scheduleAgain = false;
        await BackgroundService.reconcileScheduling();
      } while (_scheduleAgain && mounted);
    } catch (error) {
      if (mounted) {
        await ref
            .read(prefsProvider)
            .setBackgroundError(backupFailureMessage(error));
      }
    } finally {
      _scheduling = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _startTicker();
      ref.invalidate(backgroundAvailabilityProvider);
      unawaited(_reschedule());
      unawaited(_evaluate(force: true));
    } else {
      _ticker?.cancel();
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached ||
          state == AppLifecycleState.hidden) {
        ref.read(backupRunnerProvider.notifier).stopForegroundContinuation();
        unawaited(_reschedule());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    unawaited(_connectivity?.cancel());
    unawaited(_battery?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SessionState>(sessionControllerProvider, (previous, next) {
      if (next.isAuthenticated &&
          (previous?.isAuthenticated != true ||
              previous?.user?.id != next.user?.id)) {
        _scheduleEvaluation(force: true);
        unawaited(_reschedule());
      }
    });
    ref.listen<BackupSettings>(backupSettingsProvider, (_, _) {
      _scheduleEvaluation(force: true);
    });
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Keep the user-scoped live event stream alive for the whole app lifetime;
    // it self-gates on auth state and reconnects when the active server changes.
    ref.watch(liveEventsProvider);
    return MaterialApp.router(
      title: 'LocalDrive',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
