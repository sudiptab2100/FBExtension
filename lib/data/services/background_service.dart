import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/config/constants.dart';
import '../../core/network/dio_client.dart';
import '../models/ld_instance.dart';
import 'backup_engine.dart';
import 'notification_service.dart';

/// WorkManager entry point. Runs in a dedicated background isolate, so it must
/// not touch the app's Riverpod graph — it reads persisted state directly.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      switch (task) {
        case BgTasks.backup:
          await (BackgroundHooks.runBackup ?? runHeadlessBackup)();
          return true;
        case BgTasks.refresh:
        default:
          await _pollChanges();
          return true;
      }
    } catch (_) {
      // Returning false lets WorkManager retry with backoff.
      return false;
    }
  });
}

/// Poll `/api/changes` for every saved instance that has a stored token, and
/// surface new changes as local notifications. The per-instance cursor makes
/// this incremental and idempotent across wake-ups.
Future<void> _pollChanges() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(StoreKeys.savedInstances);
  if (raw == null || raw.isEmpty) return;

  List<LdInstance> instances;
  try {
    instances = (jsonDecode(raw) as List)
        .map((e) => LdInstance.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return;
  }
  if (instances.isEmpty) return;

  const secure = FlutterSecureStorage();
  final notif = NotificationService.instance;
  await notif.init();
  final notificationsOn =
      prefs.getBool(SettingKeys.notificationsEnabled) ?? true;

  for (final inst in instances) {
    final token = await secure.read(key: '${StoreKeys.tokenPrefix}${inst.id}');
    if (token == null || token.isEmpty) continue;

    final cursorKey = '${StoreKeys.lastChangeCursor}${inst.id}';
    final since = prefs.getString(cursorKey);

    final dio = buildDio(
      baseUrl: inst.baseUrl,
      token: () => token,
      trustSelfSigned: inst.trustSelfSigned,
    );
    try {
      final res = await dio.get<dynamic>(
        Api.changes,
        queryParameters: since == null ? null : {'since': since},
      );
      final data = res.data as Map<String, dynamic>;
      final changes = (data['changes'] as List?) ?? const [];
      final cursor = data['cursor'] as String?;
      if (cursor != null) await prefs.setString(cursorKey, cursor);

      if (notificationsOn && since != null && changes.isNotEmpty) {
        await _notifyChanges(notif, inst, changes);
      }
    } catch (_) {
      /* transient; try again next wake-up */
    } finally {
      dio.close();
    }
  }
}

Future<void> _notifyChanges(
  NotificationService notif,
  LdInstance inst,
  List<dynamic> changes,
) async {
  final files = changes
      .whereType<Map<String, dynamic>>()
      .where((c) => c['kind'] == 'file')
      .toList();
  final access =
      changes.whereType<Map<String, dynamic>>().any((c) => c['kind'] == 'access');

  if (files.isNotEmpty) {
    final first = files.first;
    final path = (first['path'] as String?) ?? '';
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    final name = parts.isEmpty ? path : parts.last;
    final body = files.length == 1
        ? '${first['action'] ?? 'changed'}: $name'
        : '${files.length} changes, incl. $name';
    await notif.post(title: '${inst.name}: files updated', body: body);
  }
  if (access) {
    await notif.post(
      title: '${inst.name}: access updated',
      body: 'Your drive access changed. Open the app to review.',
    );
  }
}

/// Late-bound hook so the (heavier) backup engine can register its headless
/// entry point without the background isolate importing UI code eagerly.
class BackgroundHooks {
  BackgroundHooks._();
  static Future<void> Function()? runBackup;
}

/// Registration/scheduling API for the UI isolate.
class BackgroundService {
  BackgroundService._();

  static Future<void> initialize() async {
    await Workmanager().initialize(backgroundDispatcher);
  }

  static Future<void> enableChangePolling() async {
    await Workmanager().registerPeriodicTask(
      BgTasks.refresh,
      BgTasks.refresh,
      frequency: BgTasks.minPeriod,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  static Future<void> disableChangePolling() async {
    await Workmanager().cancelByUniqueName(BgTasks.refresh);
  }

  static Future<void> enableBackup({bool wifiOnly = true}) async {
    await Workmanager().registerPeriodicTask(
      BgTasks.backup,
      BgTasks.backup,
      frequency: const Duration(hours: 1),
      constraints: Constraints(
        networkType: wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresCharging: false,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  static Future<void> disableBackup() async {
    await Workmanager().cancelByUniqueName(BgTasks.backup);
  }
}
