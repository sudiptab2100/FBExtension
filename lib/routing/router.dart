import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/admin_access_screen.dart';
import '../features/admin/admin_config_screen.dart';
import '../features/admin/admin_dashboard_screen.dart';
import '../features/admin/admin_server_screen.dart';
import '../features/admin/admin_users_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/backup/backup_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/connect/qr_scan_screen.dart';
import '../features/device/device_screen.dart';
import '../features/device/photo_grid_screen.dart';
import '../features/files/file_browser_screen.dart';
import '../features/files/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/home_shell.dart';
import '../state/connection_controller.dart';
import '../state/session_controller.dart';

/// Named route paths, referenced across the app.
class Routes {
  Routes._();
  static const splash = '/splash';
  static const connect = '/connect';
  static const qrScan = '/connect/scan';
  static const login = '/login';
  static const home = '/';
  static const files = '/files';
  static const search = '/search';
  static const device = '/device';
  static const devicePhotos = '/device/photos';
  static const backup = '/backup';
  static const settings = '/settings';
  static const admin = '/admin';
  static const adminUsers = '/admin/users';
  static const adminAccess = '/admin/access';
  static const adminConfig = '/admin/config';
  static const adminServer = '/admin/server';
}

/// The app router, guarded by connection + session state. It refreshes whenever
/// either controller changes so redirects re-evaluate.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref
    ..listen(connectionControllerProvider, (_, _) => refresh.value++)
    ..listen(sessionControllerProvider, (_, _) => refresh.value++)
    ..onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final conn = ref.read(connectionControllerProvider);
      final session = ref.read(sessionControllerProvider);
      final loc = state.matchedLocation;

      final onConnect = loc.startsWith(Routes.connect);
      final onLogin = loc == Routes.login;
      final onSplash = loc == Routes.splash;

      // 1. No server chosen → the connect/discovery chooser.
      if (conn.active == null) {
        return onConnect ? null : Routes.connect;
      }

      // 2. Restoring the saved session → splash.
      if (session.status == SessionStatus.loading) {
        return onSplash ? null : Routes.splash;
      }

      // 3. Not signed in → login.
      if (session.status != SessionStatus.authenticated) {
        return onLogin ? null : Routes.login;
      }

      // 4. Signed in → keep away from the pre-auth screens.
      if (onConnect || onLogin || onSplash) return Routes.home;
      return null;
    },
    routes: [
      GoRoute(path: Routes.splash, builder: (_, _) => const SplashScreen()),
      GoRoute(path: Routes.connect, builder: (_, _) => const ConnectScreen()),
      GoRoute(path: Routes.qrScan, builder: (_, _) => const QrScanScreen()),
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const HomeShell()),
      GoRoute(
        path: Routes.files,
        builder: (_, state) => FileBrowserScreen(
          drive: state.uri.queryParameters['drive'] ?? '',
          path: state.uri.queryParameters['path'] ?? '',
          driveLabel: state.uri.queryParameters['label'],
        ),
      ),
      GoRoute(
        path: Routes.search,
        builder: (_, state) => SearchScreen(
          initialDrive: state.uri.queryParameters['drive'],
          driveLabel: state.uri.queryParameters['label'],
        ),
      ),
      GoRoute(path: Routes.device, builder: (_, _) => const DeviceScreen()),
      GoRoute(
          path: Routes.devicePhotos,
          builder: (_, _) => const PhotoGridScreen()),
      GoRoute(path: Routes.backup, builder: (_, _) => const BackupScreen()),
      GoRoute(path: Routes.settings, builder: (_, _) => const SettingsScreen()),
      GoRoute(path: Routes.admin, builder: (_, _) => const AdminDashboardScreen()),
      GoRoute(path: Routes.adminUsers, builder: (_, _) => const AdminUsersScreen()),
      GoRoute(path: Routes.adminAccess, builder: (_, _) => const AdminAccessScreen()),
      GoRoute(path: Routes.adminConfig, builder: (_, _) => const AdminConfigScreen()),
      GoRoute(path: Routes.adminServer, builder: (_, _) => const AdminServerScreen()),
    ],
    errorBuilder: (_, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: Center(child: Text('No route for ${state.uri}')),
    ),
  );
});
