import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/constants.dart';

/// Thin wrapper over `flutter_local_notifications`.
///
/// Used both from the UI isolate (via [notificationServiceProvider]) and from
/// the WorkManager background isolate (via the static [ensureInitialized] +
/// [post] helpers), so it deliberately keeps no Flutter/Riverpod dependencies.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _seq = 1;

  /// Initialise the plugin and register Android channels. Safe to call twice.
  Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );

    final android_ = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        Notif.channelId,
        Notif.channelName,
        description: Notif.channelDesc,
        importance: Importance.defaultImportance,
      ),
    );
    await android_?.createNotificationChannel(
      const AndroidNotificationChannel(
        Notif.backupChannelId,
        Notif.backupChannelName,
        importance: Importance.low,
      ),
    );
    _ready = true;
  }

  /// Ask the OS for permission to post notifications (Android 13+, iOS).
  Future<bool> requestPermission() async {
    await init();
    if (Platform.isAndroid) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return (await impl?.requestNotificationsPermission()) ?? true;
    }
    if (Platform.isIOS) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return (await impl?.requestPermissions(
              alert: true, badge: true, sound: true)) ??
          true;
    }
    return true;
  }

  /// Post a notification. [id] defaults to an auto-incrementing sequence.
  Future<void> post({
    required String title,
    required String body,
    int? id,
    String channelId = Notif.channelId,
    String channelName = Notif.channelName,
    String? payload,
  }) async {
    await init();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
      iOS: const DarwinNotificationDetails(),
    );
    await _plugin.show(id ?? _seq++, title, body, details, payload: payload);
  }
}

/// UI-isolate accessor. Background isolates call [NotificationService.instance]
/// directly after `init()`.
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);
