import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/theme.dart';
import 'routing/router.dart';
import 'state/live_events.dart';
import 'state/settings_controller.dart';

/// Root widget: wires the router, theme, and theme-mode into [MaterialApp].
class LocalDriveApp extends ConsumerWidget {
  const LocalDriveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    // Keep the user-scoped live event stream alive for the whole app lifetime;
    // it self-gates on auth state and reconnects when the active server changes.
    ref.watch(liveEventsProvider);
    return MaterialApp.router(
      title: 'LocalDrive',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
