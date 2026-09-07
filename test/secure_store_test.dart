import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/storage/secure_store.dart';
import 'package:mocktail/mocktail.dart';

class _Storage extends Mock implements FlutterSecureStorage {}

void main() {
  setUpAll(() => registerFallbackValue(const IOSOptions()));

  test(
    'account token lookup does not filter out migrated Keychain items',
    () async {
      final storage = _Storage();
      when(
        () => storage.read(
          key: any(named: 'key'),
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async => 'test-only-token');

      expect(
        await SecureStore(storage).readUserToken('server', 'alice'),
        'test-only-token',
      );
      final captured =
          verify(
                () => storage.read(
                  key: 'ld.token.server::alice',
                  iOptions: captureAny(named: 'iOptions'),
                ),
              ).captured.single
              as IOSOptions;
      expect(captured.toMap().containsKey('accessibility'), isFalse);
    },
  );

  test(
    'token refresh preserves Keychain protection and never deletes first',
    () async {
      final storage = _Storage();
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
          iOptions: any(named: 'iOptions'),
        ),
      ).thenAnswer((_) async {});
      await SecureStore(storage)
          .writeUserToken('server', 'alice', 'new-test-token');
      final captured =
          verify(
                () => storage.write(
                  key: 'ld.token.server::alice',
                  value: 'new-test-token',
                  iOptions: captureAny(named: 'iOptions'),
                ),
              ).captured.single
              as IOSOptions;
      expect(captured.toMap().containsKey('accessibility'), isFalse);
      verifyNever(() => storage.delete(key: any(named: 'key')));
    },
  );
}
