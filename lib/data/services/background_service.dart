import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/config/constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/dio_client.dart';
import '../../core/storage/prefs.dart';
import '../models/ld_instance.dart';
import 'background_session.dart';
import 'backup_engine.dart';
import 'backup_errors.dart';
import 'notification_service.dart';

/// WorkManager entry point. Runs in a dedicated background isolate, so it must
/// not touch the app's Riverpod graph — it reads persisted state directly.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      switch (task) {
        case BgTasks.backup:
          await BackgroundService.reconcileScheduling(includeRefresh: false);
          await (BackgroundHooks.runBackup ?? runHeadlessBackup)();
          return true;
        case BgTasks.refresh:
          return await _pollChanges();
        default:
          throw UnsupportedError('Unknown background task: $task');
      }
    } catch (error, stack) {
      final prefs = await Prefs.create();
      await prefs.setBackgroundError(backupFailureMessage(error));
      if (kDebugMode) {
        debugPrintStack(
          label: 'Background task failed (${error.runtimeType})',
          stackTrace: stack,
        );
      }
      return false;
    }
  });
}

/// Poll `/api/changes` for every saved instance that has a stored token, and
/// surface new changes as local notifications. The per-instance cursor makes
/// this incremental and idempotent across wake-ups.
Future<bool> _pollChanges() async {
  final prefs = await Prefs.create();
  await prefs.reload();
  if (!prefs.notificationsEnabled) return true;
  final notif = NotificationService.instance;
  await notif.init();
  var succeeded = true;

  for (final inst in prefs.readInstances()) {
    final account = await loadBackgroundAccount(
      prefs: prefs,
      instanceId: inst.id,
    );
    if (account == null) continue;
    final since = prefs.accountChangeCursor(inst.id, account.userId);
    final dio = buildDio(
      baseUrl: inst.baseUrl,
      token: () => account.token,
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
      if (!await isBackgroundAccountCurrent(account, prefs: prefs) ||
          !prefs.notificationsEnabled) {
        continue;
      }
      if (cursor != null) {
        await prefs.setAccountChangeCursor(inst.id, account.userId, cursor);
      }

      if (since != null && changes.isNotEmpty) {
        await _notifyChanges(notif, inst, changes);
      }
    } on DioException catch (error) {
      succeeded = false;
      await prefs.setBackgroundError(
        '${inst.name}: ${ApiException.from(error).message}',
      );
    } finally {
      dio.close();
    }
  }
  return succeeded;
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
  final access = changes.whereType<Map<String, dynamic>>().any(
    (c) => c['kind'] == 'access',
  );

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

  static const _native = MethodChannel('localdrive/bg_upload');
  static Future<void> _scheduling = Future<void>.value();

  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static Future<Map<String, dynamic>?> environment() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return null;
    final result = await _native.invokeMapMethod<String, dynamic>(
      'environment',
    );
    if (result == null) {
      throw StateError(
        'iOS background status is unavailable. Reopen LocalDrive.',
      );
    }
    return result;
  }

  static Future<void> initialize() async {
    if (!isSupported) {
      throw UnsupportedError(
        'Background backup is available on iOS and Android.',
      );
    }
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

  static Constraints backupConstraints({
    required bool isIOS,
    required bool wifiOnly,
    required bool chargingOnly,
  }) => Constraints(
    networkType: isIOS || !wifiOnly
        ? NetworkType.connected
        : NetworkType.unmetered,
    requiresCharging: chargingOnly,
  );

  static Future<void> enableBackup({
    bool wifiOnly = true,
    bool chargingOnly = true,
  }) async {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    final constraints = backupConstraints(
      isIOS: ios,
      wifiOnly: wifiOnly,
      chargingOnly: chargingOnly,
    );
    if (ios) {
      await Workmanager().cancelByUniqueName(BgTasks.backup);
      await Workmanager().registerProcessingTask(
        BgTasks.backup,
        BgTasks.backup,
        initialDelay: const Duration(hours: 1),
        constraints: constraints,
      );
      final availability = await environment();
      final pending = availability?['pendingTaskIdentifiers'];
      if (pending is! List || !pending.contains(BgTasks.backup)) {
        throw StateError(
          'iOS has not scheduled backup. Check Background App Refresh and reopen the app.',
        );
      }
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw UnsupportedError(
        'Background backup is available on iOS and Android.',
      );
    }
    await Workmanager().registerPeriodicTask(
      BgTasks.backup,
      BgTasks.backup,
      frequency: const Duration(hours: 1),
      constraints: constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  static Future<void> disableBackup() async {
    await Workmanager().cancelByUniqueName(BgTasks.backup);
  }

  static Future<void> reconcileScheduling({bool includeRefresh = true}) async {
    if (!isSupported) return;
    final previous = _scheduling;
    final release = Completer<void>();
    _scheduling = release.future;
    await previous;
    try {
      await _reconcileScheduling(includeRefresh: includeRefresh);
    } finally {
      release.complete();
    }
  }

  static Future<void> _reconcileScheduling({
    required bool includeRefresh,
  }) async {
    final prefs = await Prefs.create();
    while (true) {
      await prefs.reload();
      final before = _scheduleConfiguration(prefs);
      try {
        if (includeRefresh) {
          if (prefs.notificationsEnabled) {
            await enableChangePolling();
          } else {
            await disableChangePolling();
          }
        }
        await _scheduleBackup(prefs);
      } catch (_) {
        await prefs.reload();
        if (_scheduleConfiguration(prefs) == before) rethrow;
        continue;
      }
      await prefs.reload();
      if (_scheduleConfiguration(prefs) == before) return;
    }
  }

  static String _scheduleConfiguration(Prefs prefs) {
    final id = prefs.activeInstanceId;
    final username = id == null ? null : prefs.activeAccount(id);
    final userId = id == null
        ? null
        : prefs
              .accounts(id)
              .firstWhereOrNull((account) => account.username == username)
              ?.userId;
    return jsonEncode([
      prefs.backupGeneration,
      prefs.notificationsEnabled,
      id,
      username,
      userId,
      if (id != null && userId != null) ...[
        prefs.backupAccountBlocked(id, userId),
        prefs.readBackupSettings(id, userId).toJson(),
      ],
    ]);
  }

  static Future<void> _scheduleBackup(Prefs prefs) async {
    final instanceId = prefs.activeInstanceId;
    final username = instanceId == null
        ? null
        : prefs.activeAccount(instanceId);
    final userId = instanceId == null
        ? null
        : prefs
              .accounts(instanceId)
              .firstWhereOrNull((account) => account.username == username)
              ?.userId;
    if (instanceId == null || userId == null) {
      await disableBackup();
      return;
    }
    if (prefs.backupAccountBlocked(instanceId, userId)) {
      await disableBackup();
      return;
    }
    final settings = prefs.readBackupSettings(instanceId, userId);
    if (settings.runnable) {
      await enableBackup(
        wifiOnly: settings.wifiOnly,
        chargingOnly: settings.chargingOnly,
      );
    } else {
      await disableBackup();
    }
  }
}
