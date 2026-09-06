import 'package:dio/dio.dart';

import '../../core/config/constants.dart';
import '../../core/network/api.dart';
import '../models/drive_info.dart';

/// Wraps `/api/drives/*`: the opt-in drive list, access requests, and the
/// admin-only registration surface.
class DrivesRepository {
  DrivesRepository(this._dio);
  final Dio _dio;

  /// All registered drives the caller can see, each annotated with `access`.
  Future<List<DriveInfo>> list() => guard(() async {
        final res = await _dio.get(Api.drives);
        final data = res.data as Map<String, dynamic>;
        final drives = (data['drives'] as List? ?? const []);
        return drives
            .map((e) => DriveInfo.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  /// Ask for access to a drive. Returns the resulting access state
  /// ('granted' when auto-approved or admin, else 'pending').
  Future<DriveAccess> requestAccess(String uuid) => guard(() async {
        final res = await _dio.post(Api.drivesRequestAccess, data: {'uuid': uuid});
        final data = res.data as Map<String, dynamic>;
        return driveAccessFromString(data['access']?.toString());
      });

  // ---- Admin ---------------------------------------------------------------
  /// Every detected drive (registered or not) for management. Admin-only.
  Future<List<DriveInfo>> listAll() => guard(() async {
        final res = await _dio.get(Api.drivesAll);
        final data = res.data as Map<String, dynamic>;
        final drives = (data['drives'] as List? ?? const []);
        return drives
            .map((e) => DriveInfo.fromJson(e as Map<String, dynamic>))
            .toList();
      });

  Future<DriveInfo> register(String uuid) => guard(() async {
        final res = await _dio.post(Api.drivesRegister, data: {'uuid': uuid});
        final data = res.data as Map<String, dynamic>;
        return DriveInfo.fromJson(data['drive'] as Map<String, dynamic>);
      });

  Future<void> unregister(String uuid) => guard(() async {
        await _dio.post(Api.drivesUnregister, data: {'uuid': uuid});
      });

  Future<DriveInfo> registerFolder(String path) => guard(() async {
        final res =
            await _dio.post(Api.drivesRegisterFolder, data: {'path': path});
        final data = res.data as Map<String, dynamic>;
        return DriveInfo.fromJson(data['drive'] as Map<String, dynamic>);
      });
}
