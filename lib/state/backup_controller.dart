import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../core/storage/backup_keys.dart';
import '../data/models/backup_context.dart';
import '../data/models/backup_settings.dart';
import '../data/models/backup_snapshot.dart';
import '../data/services/background_service.dart';
import '../data/services/backup_coordinator.dart';
import '../data/services/backup_errors.dart';
import '../data/services/backup_policy.dart';
import '../data/services/backup_session_actions.dart';
import '../data/services/media_service.dart';
import '../data/services/notification_service.dart';
import 'connection_controller.dart';
import 'core_providers.dart';
import 'session_controller.dart';

/// Persisted [BackupSettings], mirrored into WorkManager registration whenever
/// auto-backup eligibility changes.
class BackupSettingsController extends Notifier<BackupSettings> {
  String? configurationError;
  bool saving = false;
  int _operation = 0;
  String? _profile;

  @override
  BackupSettings build() {
    final active = ref.watch(activeInstanceProvider);
    final userId = ref.watch(
      sessionControllerProvider.select((session) => session.user?.id),
    );
    final profile = active == null || userId == null
        ? null
        : backupProfileKey(active.id, userId);
    if (_profile != profile) {
      _profile = profile;
      _operation++;
      saving = false;
    }
    configurationError = null;
    if (active == null || userId == null) return const BackupSettings();
    try {
      return ref.watch(prefsProvider).readBackupSettings(active.id, userId);
    } on FormatException {
      configurationError =
          'The saved backup settings could not be read. '
          'Choose the destination and sources again.';
    } on TypeError {
      configurationError =
          'The saved backup settings could not be read. '
          'Choose the destination and sources again.';
    }
    return const BackupSettings();
  }

  Future<bool> update(
    BackupSettings next, {
    String? expectedInstanceId,
    int? expectedUserId,
  }) async {
    if (saving) return false;
    final active = ref.read(activeInstanceProvider);
    final session = ref.read(sessionControllerProvider);
    final user = session.user;
    if (active == null || user == null || !session.isAuthenticated) {
      configurationError = 'Sign in before configuring backup.';
      state = state.copyWith();
      return false;
    }
    final prefs = ref.read(prefsProvider);
    if ((expectedInstanceId != null && active.id != expectedInstanceId) ||
        (expectedUserId != null && user.id != expectedUserId) ||
        prefs.activeAccount(active.id) != user.username) {
      configurationError =
          'The account changed. Review its backup settings first.';
      state = state.copyWith();
      return false;
    }
    final operation = ++_operation;
    int? revision;
    bool current() =>
        ref.mounted &&
        operation == _operation &&
        ref.read(activeInstanceProvider)?.id == active.id &&
        ref.read(sessionControllerProvider).user?.id == user.id &&
        prefs.activeAccount(active.id) == user.username &&
        (revision == null || prefs.backupGeneration == revision);
    saving = true;
    state = state.copyWith();
    try {
      if (next.enabled) {
        final media = ref.read(mediaServiceProvider);
        if ((next.photos || next.videos) &&
            (!state.enabled || (!state.photos && !state.videos)) &&
            !await media.requestGalleryAccess()) {
          throw StateError(
            'Allow photo access to enable automatic photo backup.',
          );
        }
        if (next.contacts &&
            (!state.enabled || !state.contacts) &&
            !await media.requestContactsAccess()) {
          throw StateError('Allow contacts access to enable contacts backup.');
        }
      }
      if (!current()) return false;
      revision = await stopAccountBackup(
        prefs: prefs,
        instanceId: active.id,
        userId: user.id,
      );
      if (!current()) return false;
      await ref
          .read(secureStoreProvider)
          .setBackgroundAccess(
            active.id,
            user.username,
            enabled: next.enabled || prefs.notificationsEnabled,
          );
      if (!current()) return false;
      await prefs.writeBackupSettings(active.id, user.id, next);
      if (!current()) return false;
      configurationError = null;
      state = next;
      await BackgroundService.reconcileScheduling();
      if (!current()) return false;
      await prefs.setBackgroundError(null);
      await ref.read(backupRunnerProvider.notifier).refresh();
      return current();
    } catch (error) {
      if (current()) {
        configurationError = backupFailureMessage(error);
        await prefs.setBackgroundError(configurationError);
      }
      return false;
    } finally {
      if (ref.mounted && operation == _operation) {
        saving = false;
        state = state.copyWith();
      }
    }
  }

  Future<void> adoptLegacySettings({
    String? expectedInstanceId,
    int? expectedUserId,
  }) async {
    final prefs = ref.read(prefsProvider);
    final active = ref.read(activeInstanceProvider);
    final user = ref.read(sessionControllerProvider).user;
    if (active == null || user == null) return;
    if ((expectedInstanceId != null && active.id != expectedInstanceId) ||
        (expectedUserId != null && user.id != expectedUserId)) {
      configurationError =
          'The account changed. Reopen Backup before importing.';
      state = state.copyWith();
      return;
    }
    try {
      final legacy = prefs.legacyBackupSettings;
      if (legacy == null) {
        throw StateError(
          'The previous backup settings could not be read. '
          'Choose a destination for this account instead.',
        );
      }
      final imported = await update(
        legacy.copyWith(enabled: false),
        expectedInstanceId: active.id,
        expectedUserId: user.id,
      );
      if (imported &&
          ref.read(activeInstanceProvider)?.id == active.id &&
          ref.read(sessionControllerProvider).user?.id == user.id) {
        await prefs.markLegacyBackupClaimed(active.id, user.id);
        state = state.copyWith();
      }
    } catch (error) {
      configurationError = backupFailureMessage(error);
      state = state.copyWith();
    }
  }
}

final backupSettingsProvider =
    NotifierProvider<BackupSettingsController, BackupSettings>(
      BackupSettingsController.new,
    );

final backupCoordinatorProvider = FutureProvider<BackupCoordinator>((
  ref,
) async {
  return BackupCoordinator(
    db: await ref.watch(localDbProvider.future),
    media: ref.watch(mediaServiceProvider),
  );
});

final backgroundAvailabilityProvider = FutureProvider<Map<String, dynamic>?>(
  (ref) => BackgroundService.environment(),
);

/// Preparation and transfer state for the visible account.
class BackupRunState {
  const BackupRunState({
    this.running = false,
    this.done = false,
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.current,
    this.error,
    this.queued = 0,
    this.paused = 0,
    this.waitingReason,
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.progress,
  });

  final bool running;
  final bool done;
  final int uploaded;
  final int skipped;
  final int failed;
  final String? current;
  final String? error;
  final int queued;
  final int paused;
  final String? waitingReason;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final double? progress;

  BackupRunState copyWith({
    bool? running,
    bool? done,
    int? uploaded,
    int? skipped,
    int? failed,
    String? current,
    String? error,
    int? queued,
    int? paused,
    String? waitingReason,
    DateTime? lastAttemptAt,
    DateTime? lastSuccessAt,
    double? progress,
    bool clearError = false,
  }) => BackupRunState(
    running: running ?? this.running,
    done: done ?? this.done,
    uploaded: uploaded ?? this.uploaded,
    skipped: skipped ?? this.skipped,
    failed: failed ?? this.failed,
    current: current,
    error: clearError ? null : (error ?? this.error),
    queued: queued ?? this.queued,
    paused: paused ?? this.paused,
    waitingReason: waitingReason,
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    progress: progress,
  );

  factory BackupRunState.fromSnapshot(
    BackupSnapshot snapshot, {
    bool preparing = false,
  }) => BackupRunState(
    running: preparing || snapshot.uploading > 0,
    done:
        !preparing &&
        !snapshot.needsScan &&
        snapshot.pending == 0 &&
        snapshot.failed == 0 &&
        snapshot.error == null &&
        snapshot.waitingReason == null &&
        snapshot.lastSuccessAt != null,
    uploaded: snapshot.completed,
    skipped: snapshot.skipped,
    failed: snapshot.failed,
    current: snapshot.current,
    error: snapshot.error,
    queued: snapshot.queued,
    paused: snapshot.paused,
    waitingReason: snapshot.waitingReason,
    lastAttemptAt: snapshot.lastAttemptAt,
    lastSuccessAt: snapshot.lastSuccessAt,
    progress: snapshot.progress,
  );
}

/// Runs a backup in the foreground with live progress. Uploads are forced into
/// the user's own space (`ld_view=user`) so admins back up personal data, not
/// the whole share.
class BackupRunner extends Notifier<BackupRunState> {
  bool _busy = false;
  bool _refreshing = false;
  String? _manualProfile;

  @override
  BackupRunState build() {
    ref.watch(activeInstanceProvider.select((instance) => instance?.id));
    ref.watch(
      sessionControllerProvider.select(
        (session) => session.isAuthenticated ? session.user?.id : null,
      ),
    );
    _manualProfile = null;
    return BackupRunState(
      running: _busy,
      waitingReason: _busy ? 'Pausing the previous backup...' : null,
    );
  }

  BackupContext? _context() {
    final active = ref.read(activeInstanceProvider);
    final session = ref.read(sessionControllerProvider);
    final user = session.user;
    final token = session.token;
    if (active == null ||
        user == null ||
        !session.isAuthenticated ||
        token == null ||
        token.isEmpty) {
      return null;
    }
    return BackupContext(
      instance: active,
      userId: user.id,
      username: user.username,
      token: token,
      settings: ref.read(backupSettingsProvider),
      generation: ref.read(prefsProvider).backupGeneration,
    );
  }

  bool _stillVisible(BackupContext context) {
    if (!ref.mounted) return false;
    final current = _context();
    return current?.profileId == context.profileId &&
        current?.generation == context.generation;
  }

  Future<void> runNow() => _run(manual: true, force: true);

  Future<void> catchUp({bool force = false}) async {
    final context = _context();
    final manual = context != null && _manualProfile == context.profileId;
    await _run(manual: manual, force: force);
  }

  Future<void> _run({required bool manual, bool force = false}) async {
    if (_busy) return;
    if (ref.read(backupSettingsProvider.notifier).saving) return;
    final context = _context();
    if (context == null) {
      if (manual) reportError('Sign in before starting a backup.');
      return;
    }
    _busy = true;
    try {
      final blocked = await backupBlockedReason(context, manual: manual);
      if (!_stillVisible(context)) return;
      if (blocked != null) {
        state = state.copyWith(
          running: false,
          done: false,
          waitingReason: blocked,
        );
        return;
      }
      final coordinator = await ref.read(backupCoordinatorProvider.future);
      await coordinator.reconcileCompletions();
      final snapshot = await coordinator.snapshot(context);
      if (!_stillVisible(context)) return;
      final now = DateTime.now().toUtc();
      final prefs = ref.read(prefsProvider);
      if (!(manual && force) && snapshot.nextRetryAt?.isAfter(now) == true) {
        state = BackupRunState.fromSnapshot(snapshot);
        return;
      }
      if (!force &&
          !snapshot.needsScan &&
          snapshot.queued == 0 &&
          snapshot.paused == 0) {
        if (snapshot.uploading > 0) return;
        final last = prefs.backupAttempt(context.profileId);
        if (!manual &&
            last != null &&
            now.difference(last) < const Duration(minutes: 15)) {
          return;
        }
      }
      if (manual && force) {
        final media = ref.read(mediaServiceProvider);
        if ((context.settings.photos || context.settings.videos) &&
            !await media.requestGalleryAccess()) {
          throw StateError('Allow photo access before starting backup.');
        }
        if (context.settings.contacts && !await media.requestContactsAccess()) {
          throw StateError('Allow contacts access before starting backup.');
        }
      }
      if (!_stillVisible(context)) return;
      await prefs.setBackupAttempt(context.profileId, now);
      if (!_stillVisible(context)) return;
      if (manual) _manualProfile = context.profileId;
      state = state.copyWith(
        running: true,
        done: false,
        clearError: true,
        lastAttemptAt: now,
      );
      final result = await coordinator.runPass(
        context: context,
        manual: manual,
        onProgress: (uploaded, skipped, failed, current) {
          if (_stillVisible(context)) {
            state = state.copyWith(
              running: true,
              uploaded: uploaded,
              skipped: skipped,
              failed: failed,
              current: current,
            );
          }
        },
      );
      if (!_stillVisible(context)) return;
      final latest = await coordinator.snapshot(context);
      if (!_stillVisible(context)) return;
      state = BackupRunState.fromSnapshot(latest);
      if (result.error != null || result.waitingReason != null) {
        state = state.copyWith(
          done: false,
          error: result.error,
          waitingReason: result.waitingReason,
        );
      }
    } catch (error) {
      if (_stillVisible(context)) reportError(backupFailureMessage(error));
    } finally {
      _busy = false;
    }
  }

  Future<void> refresh() async {
    if (_refreshing || _busy) return;
    _refreshing = true;
    final context = _context();
    try {
      final coordinator = await ref.read(backupCoordinatorProvider.future);
      await coordinator.reconcileCompletions();
      if (context == null || _busy || !_stillVisible(context)) return;
      final snapshot = await coordinator.snapshot(context);
      if (_busy || !_stillVisible(context)) return;
      state = BackupRunState.fromSnapshot(snapshot);
      if (!snapshot.needsScan && snapshot.pending == 0) {
        _manualProfile = null;
      }
      final success = snapshot.lastSuccessAt;
      final prefs = ref.read(prefsProvider);
      final key = 'ld.backup_notified.${context.profileId}';
      final stamp = success?.toUtc().toIso8601String();
      if (stamp != null &&
          snapshot.pending == 0 &&
          !snapshot.needsScan &&
          snapshot.failed == 0 &&
          snapshot.error == null &&
          snapshot.waitingReason == null &&
          prefs.notificationsEnabled &&
          prefs.readJson(key)?['at'] != stamp) {
        await ref
            .read(notificationServiceProvider)
            .post(
              title: 'Backup complete',
              body:
                  '${snapshot.completed} item(s) backed up to ${context.instance.name}',
              channelId: Notif.backupChannelId,
              channelName: Notif.backupChannelName,
            );
        await prefs.writeJson(key, {'at': stamp});
      }
    } catch (error) {
      if (context != null && _stillVisible(context)) {
        reportError(backupFailureMessage(error));
      } else if (ref.mounted) {
        await ref
            .read(prefsProvider)
            .setBackgroundError(backupFailureMessage(error));
      }
    } finally {
      _refreshing = false;
    }
  }

  void stopForegroundContinuation() => _manualProfile = null;

  void reportError(String message) {
    state = state.copyWith(running: false, done: false, error: message);
  }

  void reset() => state = const BackupRunState();
}

final backupRunnerProvider = NotifierProvider<BackupRunner, BackupRunState>(
  BackupRunner.new,
);
