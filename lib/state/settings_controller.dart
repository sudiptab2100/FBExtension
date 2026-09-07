import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/services/background_service.dart';
import '../data/services/notification_service.dart';
import 'core_providers.dart';

/// App theme mode (system/light/dark), persisted in preferences.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => _parse(ref.watch(prefsProvider).themeMode);

  static ThemeMode _parse(String s) => ThemeMode.values.firstWhere(
    (e) => e.name == s,
    orElse: () => ThemeMode.system,
  );

  Future<void> set(ThemeMode mode) async {
    await ref.read(prefsProvider).setThemeMode(mode.name);
    state = mode;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

/// Whether change/backup notifications are shown. Persisted and mirrored into
/// the background poller's WorkManager registration.
class NotificationsEnabledController extends Notifier<bool> {
  @override
  bool build() => ref.watch(prefsProvider).notificationsEnabled;

  Future<void> set(bool value) async {
    final prefs = ref.read(prefsProvider);
    await prefs.setNotificationsEnabled(value);
    state = value;
    final secure = ref.read(secureStoreProvider);
    for (final instance in prefs.readInstances()) {
      for (final account in prefs.accounts(instance.id)) {
        final userId = account.userId;
        if (userId == null ||
            await secure.readUserToken(instance.id, account.username) == null) {
          continue;
        }
        await secure.setBackgroundAccess(
          instance.id,
          account.username,
          enabled:
              value || prefs.readBackupSettings(instance.id, userId).enabled,
        );
      }
    }
    if (value) {
      await ref.read(notificationServiceProvider).requestPermission();
      await BackgroundService.enableChangePolling();
    } else {
      await BackgroundService.disableChangePolling();
    }
  }
}

final notificationsEnabledProvider =
    NotifierProvider<NotificationsEnabledController, bool>(
      NotificationsEnabledController.new,
    );
