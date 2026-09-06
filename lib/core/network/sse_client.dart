import 'dart:convert';

import 'package:dio/dio.dart';

/// A single Server-Sent Event: an [event] name and its [data] payload.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;

  /// The data payload decoded as a JSON object, or an empty map on failure.
  Map<String, dynamic> get json {
    if (data.isEmpty) return const {};
    try {
      final v = jsonDecode(data);
      return v is Map<String, dynamic> ? v : {'value': v};
    } catch (_) {
      return const {};
    }
  }
}

/// Streams Server-Sent Events from [path] using a Dio streamed response.
///
/// The server sends `event:`/`data:` frames separated by a blank line, plus
/// `:` keep-alive comments which are ignored. Auth is via the Dio bearer
/// interceptor, so this works for both `/api/events` (admin) and
/// `/api/events/user`. Cancel via the [cancelToken].
Stream<SseEvent> sseStream(
  Dio dio,
  String path, {
  CancelToken? cancelToken,
  Map<String, dynamic>? query,
}) async* {
  final response = await dio.get<ResponseBody>(
    path,
    queryParameters: query,
    options: Options(
      responseType: ResponseType.stream,
      headers: const {'Accept': 'text/event-stream'},
      // Keep the connection open indefinitely for streaming.
      receiveTimeout: Duration.zero,
    ),
    cancelToken: cancelToken,
  );

  final lines = response.data!.stream
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  var event = 'message';
  final data = StringBuffer();

  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        yield SseEvent(event, data.toString().trimRight());
      }
      event = 'message';
      data.clear();
      continue;
    }
    if (line.startsWith(':')) continue; // keep-alive comment
    if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.write('\n');
      data.write(line.substring(5).trimLeft());
    }
  }
}
