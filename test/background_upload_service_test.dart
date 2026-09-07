import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/data/services/background_upload_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('localdrive/bg_upload');
  const service = BackgroundUploadService();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'enqueue' => {'taskId': 41, 'sessionId': 'stable-wifi-session'},
        'pending' => [
          {
            'jobId': 'job',
            'attemptId': 'attempt',
            'taskId': 41,
            'sessionId': 'stable-wifi-session',
            'bytesSent': 3,
            'totalBytes': 10,
            'offset': 4,
            'state': 'running',
          },
        ],
        'readCompletions' => [
          {
            'eventId': 'event',
            'jobId': 'job',
            'attemptId': 'attempt',
            'statusCode': 503,
            'uploadOffset': 4,
            'totalBytes': 10,
            'cancelled': false,
            'completedAt': '2026-09-07T00:00:00Z',
          },
        ],
        _ => null,
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('enqueue follows the fixed file-backed PATCH handoff shape', () async {
    final task = await service.enqueue(
      jobId: 'job',
      attemptId: 'attempt',
      url: Uri.parse('https://backup.local:4843/api/upload/resource'),
      localPath: 'owned/suffix-4',
      offset: 4,
      totalBytes: 10,
      headers: const {'Cookie': 'ld_view=user', 'Upload-Offset': '4'},
      wifiOnly: true,
      trustSelfSigned: true,
      trustedOrigin: 'https://backup.local:4843',
    );
    expect(task.taskId, 41);
    expect(calls.single.method, 'enqueue');
    expect((calls.single.arguments as Map).keys.toSet(), {
      'jobId',
      'attemptId',
      'url',
      'localPath',
      'offset',
      'totalBytes',
      'headers',
      'wifiOnly',
      'trustSelfSigned',
      'trustedOrigin',
    });
    expect((calls.single.arguments as Map)['offset'], 4);
    expect((calls.single.arguments as Map)['totalBytes'], 10);
  });

  test(
    'reading failures is non-destructive until explicit acknowledgement',
    () async {
      final result = await service.readCompletions();
      expect(result.single.statusCode, 503);
      expect(result.single.uploadOffset, 4);
      expect(calls.map((call) => call.method), ['readCompletions']);
      await service.ackCompletions([result.single.eventId]);
      expect(calls.last.method, 'ackCompletions');
      expect(calls.last.arguments, {
        'eventIds': ['event'],
      });
      final task = (await service.pending()).single;
      expect(task.offset + task.bytesSent, 7);
    },
  );

  test('Android does not silently call an unsupported iOS API', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(service.isSupported, isFalse);
    await expectLater(service.pending(), throwsUnsupportedError);
    await expectLater(service.readCompletions(), throwsUnsupportedError);
    expect(calls, isEmpty);
  });

  test(
    'an incomplete native pending list is not treated as an empty task list',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          {'taskId': 41, 'sessionId': 'stable-wifi-session'},
        ],
      );
      await expectLater(service.pending(), throwsFormatException);
    },
  );

  test(
    'foreign-origin native upload locations are rejected before handoff',
    () async {
      await expectLater(
        service.enqueue(
          jobId: 'job',
          attemptId: 'attempt',
          url: Uri.parse('https://other.local/api/upload/resource'),
          localPath: 'owned/source',
          offset: 0,
          totalBytes: 10,
          headers: const {},
          wifiOnly: true,
          trustSelfSigned: false,
          trustedOrigin: 'https://backup.local:4843',
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
