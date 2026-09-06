import 'package:dio/dio.dart';

import '../../core/config/constants.dart';
import '../../core/network/api.dart';
import '../models/user.dart';

/// Result of a login/register attempt.
class AuthResult {
  const AuthResult({this.token, this.user, this.pending = false, this.message});
  final String? token;
  final AppUser? user;
  final bool pending;
  final String? message;
}

/// Public registration configuration, controlling the sign-up UI.
class AuthConfig {
  const AuthConfig({required this.registrationEnabled});
  final bool registrationEnabled;
}

/// Wraps `/api/auth/*`. Bound to one instance's [Dio].
class AuthRepository {
  AuthRepository(this._dio);
  final Dio _dio;

  Future<AuthResult> login(String username, String password) =>
      guard(() async {
        final res = await _dio.post(Api.login, data: {
          'username': username,
          'password': password,
        });
        final data = res.data as Map<String, dynamic>;
        return AuthResult(
          token: data['token'] as String?,
          user: data['user'] == null
              ? null
              : AppUser.fromJson(data['user'] as Map<String, dynamic>),
        );
      });

  Future<AuthResult> register(String username, String password) =>
      guard(() async {
        final res = await _dio.post(Api.register, data: {
          'username': username,
          'password': password,
        });
        final data = res.data as Map<String, dynamic>;
        final pending = data['pending'] == true;
        return AuthResult(
          pending: pending,
          token: data['token'] as String?,
          user: data['user'] == null
              ? null
              : AppUser.fromJson(data['user'] as Map<String, dynamic>),
          message: data['message'] as String?,
        );
      });

  Future<AppUser> me() => guard(() async {
        final res = await _dio.get(Api.me);
        final data = res.data as Map<String, dynamic>;
        return AppUser.fromJson(data['user'] as Map<String, dynamic>);
      });

  Future<AuthConfig> config() => guard(() async {
        final res = await _dio.get(Api.authConfig);
        final data = res.data as Map<String, dynamic>;
        return AuthConfig(registrationEnabled: data['registrationEnabled'] == true);
      });

  Future<void> logout() => guard(() async {
        await _dio.post(Api.logout);
      });
}
