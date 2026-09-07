import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/dio_client.dart';
import '../data/repositories/admin_repository.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/connect_repository.dart';
import '../data/repositories/drives_repository.dart';
import '../data/repositories/files_repository.dart';
import 'connection_controller.dart';
import 'session_controller.dart';

/// A [Dio] bound to the active instance. The bearer token and admin `ld_view`
/// cookie are pulled lazily from the session on each request, so this only
/// rebuilds when the active server (base URL / TLS trust) changes.
final dioProvider = Provider<Dio>((ref) {
  final active = ref.watch(activeInstanceProvider);
  // Harmless placeholder base when no server is selected; authed screens are
  // gated by the router so this is never used for real traffic.
  final baseUrl = active?.baseUrl ?? 'http://127.0.0.1:1';

  final dio = buildDio(
    baseUrl: baseUrl,
    trustSelfSigned: active?.trustSelfSigned ?? false,
    token: () {
      if (!ref.mounted || ref.read(activeInstanceProvider)?.id != active?.id) {
        return null;
      }
      return ref.read(sessionControllerProvider).token;
    },
    viewMode: () {
      if (!ref.mounted || ref.read(activeInstanceProvider)?.id != active?.id) {
        return null;
      }
      final s = ref.read(sessionControllerProvider);
      // Only admins carry an explicit view scope; users default server-side.
      return s.user?.isAdmin == true ? s.viewMode : null;
    },
    onUnauthorized: () {
      if (ref.mounted && ref.read(activeInstanceProvider)?.id == active?.id) {
        ref.read(sessionControllerProvider.notifier).handleUnauthorized();
      }
    },
  );
  ref.onDispose(dio.close);
  return dio;
});

/// Headers for authenticated binary fetches (thumbnails, previews) done outside
/// Dio, e.g. by `CachedNetworkImage`. Rebuilds on login/logout/view-toggle.
final authHeadersProvider = Provider<Map<String, String>>((ref) {
  final s = ref.watch(sessionControllerProvider);
  final headers = <String, String>{};
  if (s.token != null && s.token!.isNotEmpty) {
    headers['Authorization'] = 'Bearer ${s.token}';
  }
  if (s.user?.isAdmin == true) {
    headers['Cookie'] = 'ld_view=${s.viewMode}';
  }
  return headers;
});

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(dioProvider)),
);

final connectRepositoryProvider = Provider<ConnectRepository>(
  (ref) => ConnectRepository(ref.watch(dioProvider)),
);

final drivesRepositoryProvider = Provider<DrivesRepository>(
  (ref) => DrivesRepository(ref.watch(dioProvider)),
);

final filesRepositoryProvider = Provider<FilesRepository>(
  (ref) => FilesRepository(ref.watch(dioProvider)),
);

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(dioProvider)),
);
