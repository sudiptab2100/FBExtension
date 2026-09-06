import 'package:dio/dio.dart';

import '../../core/config/constants.dart';
import '../../core/network/api.dart';
import '../models/connect_info.dart';
import '../models/server_status.dart';

/// Wraps the unauthenticated `/api/health` probe and authenticated
/// `/api/connect` info. Used to validate a server before/after connecting.
class ConnectRepository {
  ConnectRepository(this._dio);
  final Dio _dio;

  /// Returns the server status if this is a reachable LocalDrive server.
  /// Throws [ApiException] on network failure or a non-LocalDrive endpoint.
  Future<ServerStatus> health() => guard(() async {
        final res = await _dio.get(
          Api.health,
          options: Options(receiveTimeout: const Duration(seconds: 6)),
        );
        final data = res.data as Map<String, dynamic>;
        if (data['ok'] != true || data['status'] == null) {
          throw DioException(
            requestOptions: res.requestOptions,
            response: res,
            error: 'Not a LocalDrive server',
          );
        }
        return ServerStatus.fromJson(data['status'] as Map<String, dynamic>);
      });

  Future<ConnectInfo> connect() => guard(() async {
        final res = await _dio.get(Api.connect);
        return ConnectInfo.fromJson(res.data as Map<String, dynamic>);
      });
}
