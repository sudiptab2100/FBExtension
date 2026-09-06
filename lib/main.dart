import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/constants.dart';
import 'core/storage/prefs.dart';
import 'data/models/backup_settings.dart';
import 'data/services/background_service.dart';
import 'data/services/notification_service.dart';
import 'state/core_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Preferences are loaded before the first frame so the router can decide the
  // initial destination (connect vs. login vs. home) synchronously.
  final prefs = await Prefs.create();

  // Notifications + background sync are best-effort; never block startup on them.
  await NotificationService.instance.init();
  try {
    await BackgroundService.initialize();
    if (prefs.notificationsEnabled) {
      await BackgroundService.enableChangePolling();
    }
    final backupJson = prefs.readJson(StoreKeys.backupSettings);
    if (backupJson != null) {
      final backup = BackupSettings.fromJson(backupJson);
      if (backup.runnable) {
        await BackgroundService.enableBackup(wifiOnly: backup.wifiOnly);
      }
    }
  } catch (_) {
    /* WorkManager is unavailable on some platforms/emulators; ignore. */
  }

  runApp(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs)],
      child: const LocalDriveApp(),
    ),
  );
}
