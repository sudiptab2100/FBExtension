import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

/// Exercises sqflite's real Dart opening flow with Darwin's query/execute rules.
class SqfliteChannelFixture {
  SqfliteChannelFixture({this.version = 3});

  static const channel = MethodChannel('com.tekartik.sqflite');
  static const directory = '/synthetic/localdrive-databases';
  static const path = '$directory/localdrive.db';

  final calls = <MethodCall>[];
  int version;
  bool failOpen = false;
  bool _open = false;
  List<Map<String, Object?>> Function(String sql, List<Object?> arguments)?
  query;

  void install() {
    databaseFactory = null;
    databaseFactory = databaseFactorySqflitePlugin;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  Future<void> dispose() async {
    if (_open) await (await openDatabase(path)).close();
    databaseFactory = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Iterable<MethodCall> get sqlCalls => calls.where(
    (call) => call.arguments is Map && (call.arguments as Map)['sql'] is String,
  );

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    if (call.method == 'getDatabasesPath') return directory;
    if (call.method == 'openDatabase') {
      if (failOpen) {
        throw PlatformException(code: 'sqlite_error', message: 'open_failed');
      }
      _open = true;
      return {'id': 1};
    }
    if (call.method == 'closeDatabase') {
      _open = false;
      return null;
    }
    final arguments = call.arguments;
    if (arguments is! Map || arguments['sql'] is! String) {
      throw StateError('Unexpected sqflite call: ${call.method}');
    }
    final sql = arguments['sql'] as String;
    final values = List<Object?>.from(arguments['arguments'] as List? ?? []);
    final pragmaRows = switch (sql) {
      'PRAGMA journal_mode = WAL' => [
        <String, Object?>{'journal_mode': 'wal'},
      ],
      'PRAGMA busy_timeout = 5000' => [
        <String, Object?>{'timeout': 5000},
      ],
      'PRAGMA user_version' => [
        <String, Object?>{'user_version': version},
      ],
      _ => null,
    };
    if (call.method == 'query') {
      final rows = pragmaRows ?? query?.call(sql, values);
      if (rows == null) throw StateError('Unexpected sqflite query: $sql');
      final columns = rows.isEmpty ? <String>[] : rows.first.keys.toList();
      return {
        'columns': columns,
        'rows': [
          for (final row in rows) [for (final column in columns) row[column]],
        ],
      };
    }
    if (call.method == 'execute') {
      if (pragmaRows != null) {
        throw PlatformException(
          code: 'sqlite_error',
          message: 'SQLITE_ROW returned to executeUpdate',
          details: {'sql': sql},
        );
      }
      if (sql.startsWith('PRAGMA user_version = ')) {
        version = int.parse(sql.split(' ').last);
      }
      if (arguments['inTransaction'] == true) {
        return {'transactionId': 1};
      }
      return null;
    }
    if (call.method == 'insert' || call.method == 'update') return 1;
    throw StateError('Unexpected sqflite method: ${call.method}');
  }
}
