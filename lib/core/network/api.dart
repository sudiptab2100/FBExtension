import 'package:dio/dio.dart';

import 'api_exception.dart';

/// Runs a Dio call and normalises failures to [ApiException].
Future<T> guard<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on DioException catch (e) {
    throw ApiException.from(e);
  }
}
