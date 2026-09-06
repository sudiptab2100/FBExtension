import 'package:dio/dio.dart';

/// A normalised API error with a user-presentable [message] and optional flags
/// the UI branches on (e.g. [pending] for accounts awaiting approval).
class ApiException implements Exception {
  ApiException(
    this.message, {
    this.statusCode,
    this.pending = false,
    this.isNetwork = false,
    this.isAuth = false,
  });

  final String message;
  final int? statusCode;

  /// Login was refused because the account is awaiting admin approval.
  final bool pending;

  /// Connection/timeout failure (server unreachable), not an HTTP error.
  final bool isNetwork;

  /// 401 — the caller must (re)authenticate.
  final bool isAuth;

  @override
  String toString() => message;

  /// Build an [ApiException] from a Dio error, extracting the server's
  /// `{ error }` body when present.
  factory ApiException.from(DioException e) {
    final res = e.response;
    final status = res?.statusCode;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException('Server timed out. Check the connection.',
            isNetwork: true);
      case DioExceptionType.connectionError:
        return ApiException('Could not reach the server.', isNetwork: true);
      case DioExceptionType.badCertificate:
        return ApiException(
          'The server certificate is not trusted. Approve it to continue.',
          isNetwork: true,
        );
      default:
        break;
    }

    String message = 'Request failed';
    bool pending = false;
    final body = res?.data;
    if (body is Map) {
      if (body['error'] != null) message = body['error'].toString();
      pending = body['pending'] == true;
    } else if (body is String && body.isNotEmpty && body.length < 300) {
      message = body;
    } else if (status != null) {
      message = 'Request failed ($status)';
    }

    return ApiException(
      message,
      statusCode: status,
      pending: pending,
      isAuth: status == 401,
    );
  }
}
