import '../../core/storage/local_db.dart';
import '../../core/storage/prefs.dart';
import 'background_session.dart';
import 'backup_coordinator.dart';
import 'backup_errors.dart';
import 'backup_policy.dart';

/// Confirmed completions are distinct from files merely handed to URLSession.
class BackupResult {
  const BackupResult({
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.queued = 0,
    this.error,
    this.waitingReason,
  });

  final int uploaded;
  final int skipped;
  final int failed;
  final int queued;
  final String? error;
  final String? waitingReason;
}

typedef BackupProgress = void Function(
  int uploaded,
  int skipped,
  int failed,
  String? current,
);

/// WorkManager uses the same account-scoped queue as foreground backup.
/// Completion notifications are owned by the foreground reconciler.
Future<void> runHeadlessBackup() async {
  final prefs = await Prefs.create();
  await prefs.reload();
  try {
    final coordinator = BackupCoordinator(db: await LocalDb.open());
    await coordinator.reconcileCompletions();
    final context = await loadBackupContext(prefs: prefs);
    if (context == null) return;
    final blocked = await backupBlockedReason(context);
    if (blocked != null) {
      await coordinator.db.updateBackupProfile(context, {
        'waiting_reason': blocked,
      });
      return;
    }
    await coordinator.runPass(context: context);
  } catch (error) {
    await prefs.setBackgroundError(backupFailureMessage(error));
    rethrow;
  }
}
