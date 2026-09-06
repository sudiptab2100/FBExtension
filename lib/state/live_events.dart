import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/constants.dart';
import '../core/network/sse_client.dart';
import '../data/services/notification_service.dart';
import '../features/drives/drives_screen.dart';
import '../features/files/file_browser_screen.dart';
import 'api_providers.dart';
import 'connection_controller.dart';
import 'core_providers.dart';
import 'session_controller.dart';

/// Subscribes to the user-scoped SSE stream (`/api/events/user`) while signed
/// in, refreshing affected providers live and surfacing changes made by *other*
/// people as local notifications. Rebuilds (reconnects) when the active
/// instance or auth state changes. Watch this from a long-lived widget so it
/// stays connected for the whole authenticated session.
class LiveEventsController extends Notifier<bool> {
  StreamSubscription<SseEvent>? _sub;
  CancelToken? _cancel;

  @override
  bool build() {
    ref.onDispose(_stop);
    final authed = ref.watch(
      sessionControllerProvider.select((s) => s.isAuthenticated),
    );
    final active = ref.watch(activeInstanceProvider);

    _stop();
    if (authed && active != null) {
      _start();
      return true;
    }
    return false;
  }

  void _start() {
    final dio = ref.read(dioProvider);
    _cancel = CancelToken();
    _sub = sseStream(dio, Api.eventsUser, cancelToken: _cancel).listen(
      _onEvent,
      onError: (_) {
        // The stream drops on network blips; the next rebuild reconnects.
      },
      cancelOnError: true,
    );
  }

  void _onEvent(SseEvent e) {
    switch (e.event) {
      case 'filesChanged':
        ref.invalidate(fileListProvider);
        _maybeNotifyFile(e.json);
        break;
      case 'accessChanged':
        ref.invalidate(drivesListProvider);
        if (_notificationsOn) {
          ref.read(notificationServiceProvider).post(
                title: 'Drive access updated',
                body: 'Your access to a drive changed.',
              );
        }
        break;
      case 'drivesChanged':
        ref.invalidate(drivesListProvider);
        break;
    }
  }

  bool get _notificationsOn => ref.read(prefsProvider).notificationsEnabled;

  void _maybeNotifyFile(Map<String, dynamic> data) {
    if (!_notificationsOn) return;
    final by = data['by']?.toString();
    final me = ref.read(sessionControllerProvider).user?.username;
    // Don't notify people about their own edits.
    if (by != null && me != null && by.toLowerCase() == me.toLowerCase()) {
      return;
    }
    final path = (data['path'] as String?) ?? '';
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    final name = parts.isEmpty ? 'a file' : parts.last;
    ref.read(notificationServiceProvider).post(
          title: 'Files updated',
          body: '${data['action'] ?? 'changed'}: $name',
        );
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    if (_cancel != null && !_cancel!.isCancelled) {
      _cancel!.cancel();
    }
    _cancel = null;
  }
}

final liveEventsProvider =
    NotifierProvider<LiveEventsController, bool>(LiveEventsController.new);
