import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/constants.dart';
import 'package:localdrive_app/core/network/api_exception.dart';
import 'package:localdrive_app/core/storage/backup_keys.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/core/storage/secure_store.dart';
import 'package:localdrive_app/data/models/account.dart';
import 'package:localdrive_app/data/models/backup_job.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/state/connection_controller.dart';
import 'package:localdrive_app/state/core_providers.dart';
import 'package:localdrive_app/state/session_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'support/sqflite_channel.dart';

const _owner = AppUser(
  id: 1,
  username: 'owner',
  role: UserRole.admin,
  createdAt: '',
  home: '',
  status: UserStatus.active,
);
const _normalUser = AppUser(
  id: 9,
  username: 'bob',
  role: UserRole.user,
  createdAt: '',
  home: 'bob',
  status: UserStatus.active,
);
const _oldToken = 'synthetic-owner-token';
const _newToken = 'synthetic-bob-token';
const _jobId = '11111111-1111-4111-8111-111111111111';

class _AuthenticatedSession extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: SessionStatus.authenticated,
    user: _owner,
    token: _oldToken,
  );
}

class _Tokens extends SecureStore {
  _Tokens(this.events);
  final List<String> events;
  final tokens = <(String, String), String>{};

  @override
  Future<String?> readUserToken(String instanceId, String username) async =>
      tokens[(instanceId, username)];

  @override
  Future<void> writeUserToken(
    String instanceId,
    String username,
    String token,
  ) async {
    events.add('token:$username');
    tokens[(instanceId, username)] = token;
  }

  @override
  Future<void> setBackgroundAccess(
    String instanceId,
    String username, {
    required bool enabled,
  }) async {}
}

class _Scheduler extends WorkmanagerPlatform {
  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    expect(uniqueName, BgTasks.backup);
  }
}

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nativeUploads = MethodChannel('localdrive/bg_upload');
  late SqfliteChannelFixture database;
  late WorkmanagerPlatform scheduler;
  final events = <String>[];
  var cancellationFails = false;

  setUp(() {
    Workmanager();
    scheduler = WorkmanagerPlatform.instance;
    WorkmanagerPlatform.instance = _Scheduler();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    database = SqfliteChannelFixture()..install();
    events.clear();
    cancellationFails = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeUploads, (call) async {
          expect(call.method, 'cancel');
          expect(call.arguments, {
            'jobIds': [_jobId],
          });
          events.add('cancel:$_jobId');
          if (cancellationFails) {
            throw PlatformException(
              code: 'cancel_failed',
              message: 'Could not pause the previous backup.',
            );
          }
          return null;
        });
  });

  tearDown(() async {
    await database.dispose();
    WorkmanagerPlatform.instance = scheduler;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeUploads, null);
  });

  Future<void> withSession(
    Future<void> Function(
      ProviderContainer container,
      Prefs prefs,
      _Tokens tokens,
      LdInstance instance,
    )
    action,
  ) => HttpOverrides.runWithHttpOverrides(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, Api.login);
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'user': _normalUser.toJson(), 'token': _newToken}),
      );
      await request.response.close();
    });
    final instance = LdInstance(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      name: 'Synthetic session server',
      source: InstanceSource.manual,
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await Prefs.create();
    await prefs.writeInstances([instance]);
    await prefs.setActiveInstanceId(instance.id);
    await prefs.writeAccounts(instance.id, [Account.fromUser(_owner)]);
    await prefs.setActiveAccount(instance.id, _owner.username);
    final tokens = _Tokens(events)
      ..tokens[(instance.id, _owner.username)] = _oldToken;
    final profile = backupProfileKey(instance.id, _owner.id);
    final job = BackupJob(
      jobId: _jobId,
      instanceId: instance.id,
      profileId: profile,
      userId: _owner.id,
      destinationId: '["drive","Backup"]',
      assetId: 'synthetic-photo',
      sourceKind: BackupSourceKind.photo,
      drive: 'drive',
      remotePath: 'Backup/Photos',
      filename: 'photo.jpg',
      localPath: 'synthetic/staged/photo.jpg',
      state: BackupJobState.ready,
      createdAt: DateTime.utc(2026),
    );
    database.query = (sql, arguments) {
      expect(
        sql,
        startsWith('SELECT * FROM upload_queue WHERE profile_id = ?'),
      );
      expect(arguments, [profile]);
      return [job.toMap()];
    };
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        secureStoreProvider.overrideWithValue(tokens),
        activeInstanceProvider.overrideWithValue(instance),
        sessionControllerProvider.overrideWith(_AuthenticatedSession.new),
      ],
    );
    addTearDown(container.dispose);
    await action(container, prefs, tokens, instance);
  }, _LoopbackHttp());

  test(
    'normal-user login pauses the old account before replacing credentials',
    () async {
      await withSession((container, prefs, tokens, instance) async {
        await container
            .read(sessionControllerProvider.notifier)
            .login(_normalUser.username, 'synthetic-password');
        final session = container.read(sessionControllerProvider);
        expect(session.user?.id, _normalUser.id);
        expect(session.isAdmin, isFalse);
        expect(prefs.activeAccount(instance.id), _normalUser.username);
        expect(tokens.tokens[(instance.id, _owner.username)], _oldToken);
        expect(tokens.tokens[(instance.id, _normalUser.username)], _newToken);
        expect(events, ['cancel:$_jobId', 'token:${_normalUser.username}']);
        final update = database.sqlCalls.singleWhere(
          (call) => ((call.arguments as Map)['sql'] as String).startsWith(
            'UPDATE upload_queue SET status =',
          ),
        );
        final arguments = (update.arguments as Map)['arguments'] as List;
        expect(arguments.first, 'paused');
        expect(arguments.last, backupProfileKey(instance.id, _owner.id));
        expect(
          database.sqlCalls.any(
            (call) => ((call.arguments as Map)['sql'] as String).startsWith(
              'DELETE FROM upload_queue',
            ),
          ),
          isFalse,
        );
      });
    },
  );

  for (final failure in ['database open', 'native cancellation']) {
    test('$failure failure cannot activate another account', () async {
      database.failOpen = failure == 'database open';
      cancellationFails = failure == 'native cancellation';
      await withSession((container, prefs, tokens, instance) async {
        await expectLater(
          container
              .read(sessionControllerProvider.notifier)
              .login(_normalUser.username, 'synthetic-password'),
          throwsA(isA<ApiException>()),
        );
        final session = container.read(sessionControllerProvider);
        expect(session.user?.id, _owner.id);
        expect(session.token, _oldToken);
        expect(session.message, isNotEmpty);
        expect(prefs.activeAccount(instance.id), _owner.username);
        expect(tokens.tokens, {(instance.id, _owner.username): _oldToken});
        expect(events.where((event) => event.startsWith('token:')), isEmpty);
      });
    });
  }
}
