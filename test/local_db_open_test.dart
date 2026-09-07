import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/storage/local_db.dart';
import 'package:sqflite/sqflite.dart';

import 'support/sqflite_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqfliteChannelFixture native;

  setUp(() {
    native = SqfliteChannelFixture()..install();
  });
  tearDown(() async => native.dispose());

  test(
    'the Darwin fixture rejects result-returning execute operations',
    () async {
      final db = await openDatabase(SqfliteChannelFixture.path);
      await expectLater(
        db.execute('PRAGMA busy_timeout = 5000'),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.rawQuery('PRAGMA busy_timeout = 5000'), [
        {'timeout': 5000},
      ]);
    },
  );

  for (final version in [0, 1, 2, 3]) {
    test(
      'LocalDb.open configures storage before opening schema $version',
      () async {
        native.version = version;
        final db = await LocalDb.open();
        expect(db.raw.isOpen, isTrue);
        expect(native.version, LocalDb.schemaVersion);
        final calls = native.sqlCalls.toList();
        expect(
          calls
              .take(2)
              .map((call) => (call.method, (call.arguments as Map)['sql'])),
          [
            ('query', 'PRAGMA journal_mode = WAL'),
            ('query', 'PRAGMA busy_timeout = 5000'),
          ],
        );
        final statements = calls.map(
          (call) => ((call.arguments as Map)['sql'] as String).trimLeft(),
        );
        expect(statements.any((sql) => sql.startsWith('DROP TABLE')), isFalse);
        expect(statements.any((sql) => sql.startsWith('DELETE FROM')), isFalse);
        if (version > 0) {
          expect(
            statements.any((sql) => sql.contains('CREATE TABLE backup_ledger')),
            isFalse,
          );
        }
        if (version == LocalDb.schemaVersion) {
          expect(
            statements.any((sql) => sql.startsWith('ALTER TABLE')),
            isFalse,
          );
        }
      },
    );
  }

  test(
    'reopening reconfigures the connection without rerunning migrations',
    () async {
      final first = await LocalDb.open();
      await first.raw.close();
      native.calls.clear();
      final reopened = await LocalDb.open();
      expect(reopened.raw.isOpen, isTrue);
      expect(
        native.sqlCalls
            .where(
              (call) =>
                  (call.arguments as Map)['sql'] ==
                  'PRAGMA busy_timeout = 5000',
            )
            .single
            .method,
        'query',
      );
      expect(native.version, LocalDb.schemaVersion);
      expect(
        native.sqlCalls.any(
          (call) => RegExp(r'^(CREATE|ALTER|DROP|DELETE)\s')
              .hasMatch(((call.arguments as Map)['sql'] as String).trimLeft()),
        ),
        isFalse,
      );
    },
  );

  test('a genuine native opening failure is propagated', () async {
    native.failOpen = true;
    await expectLater(LocalDb.open(), throwsA(isA<DatabaseException>()));
    expect(native.sqlCalls, isEmpty);
  });
}
