import '../../core/storage/local_db.dart';
import '../../core/storage/prefs.dart';
import 'background_service.dart';
import 'backup_coordinator.dart';

Future<int?> stopAccountBackup({
  required Prefs prefs,
  required String instanceId,
  required int? userId,
  bool discard = false,
  bool invalidateSession = true,
  bool blockNewWork = false,
}) async {
  if (blockNewWork && userId != null) {
    await prefs.setBackupAccountBlocked(instanceId, userId, true);
  }
  final revision = invalidateSession
      ? await prefs.invalidateBackupSession()
      : null;
  if (userId != null) {
    final coordinator = BackupCoordinator(db: await LocalDb.open());
    if (discard) {
      await coordinator.cancelProfile(instanceId, userId, discard: true);
    } else {
      await coordinator.pauseProfile(instanceId, userId);
    }
  }
  if (revision != null && BackgroundService.isSupported) {
    await prefs.reload();
    if (prefs.backupGeneration == revision) {
      await BackgroundService.disableBackup();
      await prefs.reload();
      if (prefs.backupGeneration != revision) {
        await BackgroundService.reconcileScheduling(includeRefresh: false);
      }
    }
  }
  return revision;
}
