import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../data/models/backup_settings.dart';
import '../data/services/backup_engine.dart';
import '../data/services/background_service.dart';
import '../data/services/media_service.dart';
import '../data/services/notification_service.dart';
import '../data/services/upload_service.dart';
import 'api_providers.dart';
import 'connection_controller.dart';
import 'core_providers.dart';

/// Persisted [BackupSettings], mirrored into WorkManager registration whenever
/// auto-backup eligibility changes.
class BackupSettingsController extends Notifier<BackupSettings> {
  @override
  BackupSettings build() {
    final json = ref.watch(prefsProvider).readJson(StoreKeys.backupSettings);
    return json == null ? const BackupSettings() : BackupSettings.fromJson(json);
  }

  Future<void> update(BackupSettings next) async {
    await ref.read(prefsProvider).writeJson(
          StoreKeys.backupSettings,
          next.toJson(),
        );
    state = next;
    if (next.runnable) {
      await BackgroundService.enableBackup(wifiOnly: next.wifiOnly);
    } else {
      await BackgroundService.disableBackup();
    }
  }
}

final backupSettingsProvider =
    NotifierProvider<BackupSettingsController, BackupSettings>(
        BackupSettingsController.new);

/// Progress/summary of a manual backup pass.
class BackupRunState {
  const BackupRunState({
    this.running = false,
    this.done = false,
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.current,
    this.error,
  });

  final bool running;
  final bool done;
  final int uploaded;
  final int skipped;
  final int failed;
  final String? current;
  final String? error;

  BackupRunState copyWith({
    bool? running,
    bool? done,
    int? uploaded,
    int? skipped,
    int? failed,
    String? current,
    String? error,
  }) =>
      BackupRunState(
        running: running ?? this.running,
        done: done ?? this.done,
        uploaded: uploaded ?? this.uploaded,
        skipped: skipped ?? this.skipped,
        failed: failed ?? this.failed,
        current: current,
        error: error ?? this.error,
      );
}

/// Runs a backup in the foreground with live progress. Uploads are forced into
/// the user's own space (`ld_view=user`) so admins back up personal data, not
/// the whole share.
class BackupRunner extends Notifier<BackupRunState> {
  @override
  BackupRunState build() => const BackupRunState();

  Future<void> runNow() async {
    if (state.running) return;
    final settings = ref.read(backupSettingsProvider);
    final active = ref.read(activeInstanceProvider);
    if (active == null || !settings.hasDestination || !settings.hasSource) {
      state = const BackupRunState(
        done: true,
        error: 'Choose a destination and at least one source first.',
      );
      return;
    }

    state = const BackupRunState(running: true);

    final headers = {...ref.read(authHeadersProvider)};
    headers['Cookie'] = '${ViewCookie.name}=${ViewCookie.user}';
    final upload = UploadService(
      baseUrl: active.baseUrl,
      headers: headers,
      trustSelfSigned: active.trustSelfSigned,
    );
    final db = await ref.read(localDbProvider.future);

    final engine = BackupEngine(
      instanceId: active.id,
      settings: settings,
      media: ref.read(mediaServiceProvider),
      upload: upload,
      db: db,
      onProgress: (u, s, f, cur) {
        state = state.copyWith(
            running: true, uploaded: u, skipped: s, failed: f, current: cur);
      },
    );
    final res = await engine.run();

    state = BackupRunState(
      done: true,
      uploaded: res.uploaded,
      skipped: res.skipped,
      failed: res.failed,
      error: res.error,
    );

    if (res.uploaded > 0 && ref.read(prefsProvider).notificationsEnabled) {
      await ref.read(notificationServiceProvider).post(
            title: 'Backup complete',
            body: '${res.uploaded} item(s) backed up',
            channelId: Notif.backupChannelId,
            channelName: Notif.backupChannelName,
          );
    }
  }

  void reset() => state = const BackupRunState();
}

final backupRunnerProvider =
    NotifierProvider<BackupRunner, BackupRunState>(BackupRunner.new);
