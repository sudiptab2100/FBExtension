import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../models/backup_context.dart';
import '../models/backup_settings.dart';
import 'background_session.dart';

String? backupPolicyReason({
  required BackupSettings settings,
  required bool active,
  required bool connected,
  required bool wifi,
  required bool charging,
  bool manual = false,
}) {
  if (!active) return 'Paused because another account or server is selected.';
  if (!manual && !settings.enabled) return 'Automatic backup is off.';
  if (!settings.hasDestination) return 'Choose a backup destination.';
  if (!settings.hasSource) return 'Choose at least one backup source.';
  if (!connected) return 'Waiting for a network connection.';
  if (settings.wifiOnly && !wifi) return 'Waiting for Wi-Fi.';
  if (!manual && settings.chargingOnly && !charging) {
    return 'Waiting for the charger.';
  }
  return null;
}

Future<String?> backupBlockedReason(
  BackupContext context, {
  bool manual = false,
}) async {
  final active = await isBackupContextActive(context);
  if (!active ||
      (!manual && !context.settings.enabled) ||
      !context.settings.hasDestination ||
      !context.settings.hasSource) {
    return backupPolicyReason(
      settings: context.settings,
      active: active,
      connected: true,
      wifi: true,
      charging: true,
      manual: manual,
    );
  }
  final connections = await Connectivity().checkConnectivity();
  final power = !manual && context.settings.chargingOnly
      ? await Battery().batteryState
      : BatteryState.charging;
  return backupPolicyReason(
    settings: context.settings,
    active: active,
    connected: connections.any((value) => value != ConnectivityResult.none),
    wifi:
        connections.contains(ConnectivityResult.wifi) ||
        connections.contains(ConnectivityResult.ethernet),
    charging: power == BatteryState.charging || power == BatteryState.full,
    manual: manual,
  );
}
