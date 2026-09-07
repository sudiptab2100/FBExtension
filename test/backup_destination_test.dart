import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/theme.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/features/device/destination_picker.dart';
import 'package:localdrive_app/state/connection_controller.dart';
import 'package:localdrive_app/state/session_controller.dart';

const _server = LdInstance(
  scheme: 'http',
  host: 'synthetic.local',
  port: 4820,
  name: 'Synthetic server',
  source: InstanceSource.manual,
);

class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(
    status: SessionStatus.authenticated,
    token: 'synthetic-token',
    user: AppUser(
      id: 7,
      username: 'alice',
      role: UserRole.admin,
      createdAt: '',
      home: 'alice',
      status: UserStatus.active,
    ),
  );
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = [value.toString()];
  }

  @override
  void forEach(void Function(String, List<String>) action) {
    values.forEach(action);
  }
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Object body) : _body = utf8.encode(jsonEncode(body));
  final List<int> _body;

  @override
  final HttpHeaders headers = _Headers()
    ..set(HttpHeaders.contentTypeHeader, 'application/json');
  @override
  int get statusCode => 200;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  String get reasonPhrase => 'OK';

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.uri);
  @override
  final Uri uri;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  bool persistentConnection = true;

  @override
  Future<HttpClientResponse> close() async => _Response(
    uri.path == '/api/drives'
        ? {
            'drives': [
              {
                'uuid': 'synthetic-drive',
                'label': 'Synthetic drive',
                'access': 'granted',
                'online': true,
                'writable': true,
              },
            ],
          }
        : {'entries': <Object>[]},
  );
}

class _Client extends Fake implements HttpClient {
  final requests = <_Request>[];
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 3);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    expect(method, 'GET');
    final request = _Request(url);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final userSpace in [true, false]) {
    testWidgets(
      userSpace
          ? 'backup folder browsing forces the captured admin into personal scope'
          : 'ordinary destination browsing keeps the admin view mode',
      (tester) async {
        final client = _Client();
        DestinationChoice? choice;
        await HttpOverrides.runZoned(() async {
          final container = ProviderContainer(
            overrides: [
              activeInstanceProvider.overrideWithValue(_server),
              sessionControllerProvider.overrideWith(_Session.new),
            ],
          );
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: AppTheme.light(),
                home: Scaffold(
                  body: Builder(
                    builder: (context) => FilledButton(
                      onPressed: () async {
                        choice = await showDestinationPicker(
                          context,
                          userSpace: userSpace,
                        );
                      },
                      child: const Text('Choose destination'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Choose destination'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Synthetic drive'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final folderRequest = client.requests
              .where((request) => request.uri.path == '/api/files/list')
              .single;
          expect(folderRequest.uri.host, _server.host);
          expect(folderRequest.uri.queryParameters['path'], '');
          for (final request in client.requests) {
            expect(request.headers.values['cookie'], [
              userSpace ? 'ld_view=user' : 'ld_view=admin',
            ]);
            expect(request.headers.values['authorization'], [
              'Bearer synthetic-token',
            ]);
          }
          expect(container.read(sessionControllerProvider).viewMode, 'admin');
          await tester.tap(
            find.text(
              userSpace
                  ? 'Back up here (my space)'
                  : 'Upload here (drive root)',
            ),
          );
          await tester.pumpAndSettle();
          expect(choice?.drive, 'synthetic-drive');
          expect(choice?.path, '');
          await tester.pumpWidget(const SizedBox.shrink());
        }, createHttpClient: (_) => client);
      },
    );
  }
}
