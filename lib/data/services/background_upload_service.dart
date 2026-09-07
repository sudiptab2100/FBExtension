import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeUploadTask {
  const NativeUploadTask({
    required this.taskId,
    required this.sessionId,
    this.jobId = '',
    this.attemptId = '',
    this.bytesSent = 0,
    this.totalBytes = 0,
    this.offset = 0,
    this.state = 'uploading',
  });

  final int taskId;
  final String sessionId;
  final String jobId;
  final String attemptId;
  final int bytesSent;
  final int totalBytes;
  final int offset;
  final String state;

  factory NativeUploadTask.fromMap(Map<Object?, Object?> value) =>
      NativeUploadTask(
        taskId: value['taskId'] as int,
        sessionId: value['sessionId'] as String,
        jobId: value['jobId'] as String? ?? '',
        attemptId: value['attemptId'] as String? ?? '',
        bytesSent: value['bytesSent'] as int? ?? 0,
        totalBytes: value['totalBytes'] as int? ?? 0,
        offset: value['offset'] as int? ?? 0,
        state: value['state'] as String? ?? 'uploading',
      );
}

class NativeUploadCompletion {
  const NativeUploadCompletion({
    required this.eventId,
    required this.jobId,
    required this.attemptId,
    required this.totalBytes,
    required this.cancelled,
    required this.completedAt,
    this.statusCode,
    this.uploadOffset,
    this.errorCode,
    this.errorMessage,
    this.responseUrl,
  });

  final String eventId;
  final String jobId;
  final String attemptId;
  final int? statusCode;
  final int? uploadOffset;
  final int totalBytes;
  final bool cancelled;
  final String? errorCode;
  final String? errorMessage;
  final DateTime completedAt;
  final String? responseUrl;

  factory NativeUploadCompletion.fromMap(Map<Object?, Object?> value) =>
      NativeUploadCompletion(
        eventId: value['eventId'] as String,
        jobId: value['jobId'] as String,
        attemptId: value['attemptId'] as String,
        statusCode: value['statusCode'] as int?,
        uploadOffset: value['uploadOffset'] as int?,
        totalBytes: value['totalBytes'] as int,
        cancelled: value['cancelled'] as bool,
        errorCode: value['errorCode'] as String?,
        errorMessage: value['errorMessage'] as String?,
        completedAt: DateTime.parse(value['completedAt'] as String),
        responseUrl: value['responseUrl'] as String?,
      );
}

/// iOS's durable task/event journal. Android never invokes these channels.
class BackgroundUploadService {
  const BackgroundUploadService({
    this.channel = const MethodChannel('localdrive/bg_upload'),
    this.events = const EventChannel('localdrive/bg_upload/events'),
  });

  final MethodChannel channel;
  final EventChannel events;
  static const channelTimeout = Duration(seconds: 25);

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void _requireSupport() {
    if (!isSupported) {
      throw UnsupportedError('Native background uploads are available on iOS.');
    }
  }

  Future<NativeUploadTask> enqueue({
    required String jobId,
    required String attemptId,
    required Uri url,
    required String localPath,
    required int offset,
    required int totalBytes,
    required Map<String, String> headers,
    required bool wifiOnly,
    required bool trustSelfSigned,
    required String trustedOrigin,
  }) async {
    _requireSupport();
    final origin = Uri.parse(trustedOrigin);
    if (url.origin != origin.origin ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        offset < 0 ||
        offset > totalBytes) {
      throw ArgumentError(
        'Invalid native backup transfer destination or offset.',
      );
    }
    final result = await channel
        .invokeMapMethod<Object?, Object?>('enqueue', {
          'jobId': jobId,
          'attemptId': attemptId,
          'url': url.toString(),
          'localPath': localPath,
          'offset': offset,
          'totalBytes': totalBytes,
          'headers': headers,
          'wifiOnly': wifiOnly,
          'trustSelfSigned': trustSelfSigned,
          'trustedOrigin': origin.origin,
        })
        .timeout(channelTimeout);
    if (result == null) {
      throw StateError('Native backup did not return a durable task identity.');
    }
    return NativeUploadTask.fromMap(result);
  }

  Future<List<NativeUploadTask>> pending() async {
    _requireSupport();
    final result = await channel
        .invokeListMethod<Object?>('pending')
        .timeout(channelTimeout);
    if (result == null) {
      throw StateError('Native backup did not return its pending tasks.');
    }
    return result.map((item) {
      final task = NativeUploadTask.fromMap(item as Map<Object?, Object?>);
      if (task.jobId.isEmpty ||
          task.attemptId.isEmpty ||
          task.sessionId.isEmpty ||
          task.totalBytes < 0 ||
          task.offset < 0) {
        throw const FormatException('Incomplete native pending-task identity.');
      }
      return task;
    }).toList();
  }

  Future<void> cancel(List<String> jobIds) async {
    _requireSupport();
    if (jobIds.isEmpty) return;
    await channel
        .invokeMethod<void>('cancel', {'jobIds': jobIds})
        .timeout(channelTimeout);
  }

  Future<List<NativeUploadCompletion>> readCompletions() async {
    _requireSupport();
    final result = await channel
        .invokeListMethod<Object?>('readCompletions')
        .timeout(channelTimeout);
    if (result == null) {
      throw StateError('Native backup did not return its completion journal.');
    }
    return result.map((item) {
      final event = NativeUploadCompletion.fromMap(
        item as Map<Object?, Object?>,
      );
      if (event.eventId.isEmpty ||
          event.jobId.isEmpty ||
          event.attemptId.isEmpty ||
          event.totalBytes < 0) {
        throw const FormatException('Incomplete native completion identity.');
      }
      return event;
    }).toList();
  }

  Future<void> ackCompletions(List<String> eventIds) async {
    _requireSupport();
    if (eventIds.isEmpty) return;
    await channel
        .invokeMethod<void>('ackCompletions', {'eventIds': eventIds})
        .timeout(channelTimeout);
  }

  Stream<Map<Object?, Object?>> get progress {
    _requireSupport();
    return events.receiveBroadcastStream().map(
      (event) => event as Map<Object?, Object?>,
    );
  }
}
