import 'package:dio/dio.dart';

import '../../core/config/constants.dart';
import '../../core/network/api.dart';
import '../models/access_request.dart';
import '../models/acl.dart';
import '../models/app_config.dart';
import '../models/server_status.dart';
import '../models/user.dart';

/// Wraps the admin-only surface: users + ACLs, access approvals, config, and
/// server lifecycle. Every call here requires an admin bearer token.
class AdminRepository {
  AdminRepository(this._dio);
  final Dio _dio;

  // ---- Users ---------------------------------------------------------------
  Future<List<AdminUser>> users() => guard(() async {
        final res = await _dio.get(Api.users);
        final data = res.data as Map<String, dynamic>;
        return (data['users'] as List? ?? const [])
            .map((e) => AdminUser.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  Future<AppUser> createUser(String username, String password, String role) =>
      guard(() async {
        final res = await _dio.post(Api.users,
            data: {'username': username, 'password': password, 'role': role});
        final data = res.data as Map<String, dynamic>;
        return AppUser.fromJson(data['user'] as Map<String, dynamic>);
      });

  Future<void> deleteUser(int id) => guard(() async {
        await _dio.delete('${Api.users}/$id');
      });

  Future<void> approveUser(int id) => guard(() async {
        await _dio.post('${Api.users}/$id/approve');
      });

  Future<void> setPassword(int id, String password) => guard(() async {
        await _dio.post('${Api.users}/$id/password', data: {'password': password});
      });

  Future<void> setRole(int id, String role) => guard(() async {
        await _dio.post('${Api.users}/$id/role', data: {'role': role});
      });

  // ---- ACLs ----------------------------------------------------------------
  Future<void> setAcl(int userId, String drive, String pathPrefix, String permission) =>
      guard(() async {
        await _dio.post(Api.userAcls, data: {
          'userId': userId,
          'drive': drive,
          'pathPrefix': pathPrefix,
          'permission': permission,
        });
      });

  Future<void> removeAcl(int id) => guard(() async {
        await _dio.delete('${Api.userAcls}/$id');
      });

  // ---- Access requests -----------------------------------------------------
  Future<List<AccessRequest>> accessRequests() => guard(() async {
        final res = await _dio.get(Api.access);
        final data = res.data as Map<String, dynamic>;
        return (data['requests'] as List? ?? const [])
            .map((e) => AccessRequest.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  Future<void> approveAccess(int id) => guard(() async {
        await _dio.post('${Api.access}/$id/approve');
      });

  Future<void> denyAccess(int id) => guard(() async {
        await _dio.post('${Api.access}/$id/deny');
      });

  // ---- Config --------------------------------------------------------------
  Future<AppConfig> config() => guard(() async {
        final res = await _dio.get(Api.config);
        return AppConfig.fromJson(res.data as Map<String, dynamic>);
      });

  /// Patch config keys. Returns the new config and whether a restart occurred.
  Future<({AppConfig config, bool restarted})> patchConfig(
    Map<String, dynamic> patch,
  ) =>
      guard(() async {
        final res = await _dio.patch(Api.config, data: patch);
        final data = res.data as Map<String, dynamic>;
        return (
          config: AppConfig.fromJson(data['config'] as Map<String, dynamic>),
          restarted: data['restarted'] == true,
        );
      });

  // ---- Server lifecycle ----------------------------------------------------
  Future<ServerStatus> startServer() => guard(() async {
        final res = await _dio.post(Api.serverStart);
        final data = res.data as Map<String, dynamic>;
        return ServerStatus.fromJson(data['status'] as Map<String, dynamic>);
      });

  Future<void> stopServer() => guard(() async {
        await _dio.post(Api.serverStop);
      });

  Future<void> restartServer() => guard(() async {
        await _dio.post(Api.serverRestart);
      });

  // ---- Stats ---------------------------------------------------------------
  Future<Map<String, dynamic>> dashboard() => guard(() async {
        final res = await _dio.get(Api.stats);
        return res.data as Map<String, dynamic>;
      });
}
