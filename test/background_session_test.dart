import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localdrive_app/core/config/constants.dart';
import 'package:localdrive_app/core/storage/prefs.dart';
import 'package:localdrive_app/core/storage/secure_store.dart';
import 'package:localdrive_app/data/models/account.dart';
import 'package:localdrive_app/data/models/backup_context.dart';
import 'package:localdrive_app/data/models/backup_settings.dart';
import 'package:localdrive_app/data/models/ld_instance.dart';
import 'package:localdrive_app/data/models/user.dart';
import 'package:localdrive_app/data/services/background_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _instance = LdInstance(
  scheme: 'http',
  host: 'backup.local',
  port: 4820,
  name: 'Backup server',
  source: InstanceSource.manual,
);

class _Tokens extends SecureStore {
  _Tokens({this.onRead});

  final Future<void> Function()? onRead;
  final reads = <String>[];

  @override
  Future<String?> readUserToken(String instanceId, String username) async {
    reads.add('$instanceId::$username');
    await onRead?.call();
    return 'test-only-session-token';
  }

  @override
  Future<String?> readToken(String instanceId) =>
      throw StateError('Headless work must not read the legacy token.');
}

Future<Prefs> _prefs({bool active = true, int? userId = 7}) async {
  SharedPreferences.setMockInitialValues({
    StoreKeys.savedInstances: jsonEncode([_instance.toJson()]),
    StoreKeys.activeInstanceId: _instance.id,
    '${StoreKeys.accountsPrefix}${_instance.id}': jsonEncode([
      Account(
        username: 'alice',
        userId: userId,
        role: UserRole.user,
        addedAt: 't',
      ).toJson(),
      const Account(
        username: 'bob',
        userId: 9,
        role: UserRole.user,
        addedAt: 't',
      ).toJson(),
    ]),
    if (active) '${StoreKeys.activeAccountPrefix}${_instance.id}': 'alice',
  });
  return Prefs.create();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'headless work reads the selected per-account token, never the old key',
    () async {
      final prefs = await _prefs();
      final tokens = _Tokens();
      final account = await loadBackgroundAccount(
        prefs: prefs,
        secureStore: tokens,
      );
      expect(account?.username, 'alice');
      expect(account?.userId, 7);
      expect(tokens.reads, ['${_instance.id}::alice']);
    },
  );

  test(
    'no selected account does not silently choose the first saved user',
    () async {
      final prefs = await _prefs(active: false);
      final tokens = _Tokens();
      expect(
        await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
        isNull,
      );
      expect(tokens.reads, isEmpty);
    },
  );

  test(
    'account selection is rechecked after an asynchronous token read',
    () async {
      final prefs = await _prefs();
      final tokens = _Tokens(
        onRead: () => prefs.setActiveAccount(_instance.id, 'bob'),
      );
      expect(
        await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
        isNull,
      );
    },
  );

  test('a token read cannot borrow a newer backup generation', () async {
    final prefs = await _prefs();
    final tokens = _Tokens(
      onRead: () async {
        await prefs.invalidateBackupSession();
      },
    );
    expect(
      await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
      isNull,
    );
    expect(prefs.backupGeneration, 1);
  });

  test('logout during a token read prevents background work', () async {
    final prefs = await _prefs();
    final tokens = _Tokens(
      onRead: () => prefs.setBackupAccountBlocked(_instance.id, 7, true),
    );
    expect(
      await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
      isNull,
    );
  });

  test('a removed server cannot produce a late background session', () async {
    final prefs = await _prefs();
    final tokens = _Tokens(onRead: () => prefs.writeInstances([]));
    expect(
      await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
      isNull,
    );
  });

  test('unverified historical identity requires foreground sign-in', () async {
    final prefs = await _prefs(userId: null);
    final tokens = _Tokens();
    expect(
      await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
      isNull,
    );
    expect(tokens.reads, isEmpty);
    expect(prefs.backgroundError, contains('confirm the backup account'));
  });

  test('backup settings cannot leak from Alice into Bob', () async {
    final prefs = await _prefs();
    await prefs.writeBackupSettings(
      _instance.id,
      7,
      const BackupSettings(enabled: true, driveUuid: 'alice-drive'),
    );
    expect(prefs.readBackupSettings(_instance.id, 7).driveUuid, 'alice-drive');
    expect(prefs.readBackupSettings(_instance.id, 9).enabled, isFalse);
    expect(prefs.readBackupSettings(_instance.id, 9).driveUuid, isNull);
  });

  test('global legacy settings require an explicit ownership choice', () async {
    final prefs = await _prefs();
    await prefs.writeJson(
      StoreKeys.backupSettings,
      const BackupSettings(enabled: true, driveUuid: 'old-drive').toJson(),
    );
    expect(prefs.hasUnclaimedLegacyBackup, isTrue);
    expect(prefs.readBackupSettings(_instance.id, 7).driveUuid, isNull);
    await prefs.markLegacyBackupClaimed(_instance.id, 7);
    expect(prefs.hasUnclaimedLegacyBackup, isFalse);
    expect(prefs.legacyBackupSettings?.driveUuid, 'old-drive');
  });

  test(
    'invalidating a session is persistent across preference reloads',
    () async {
      final prefs = await _prefs();
      expect(prefs.backupGeneration, 0);
      await prefs.invalidateBackupSession();
      final reopened = await Prefs.create();
      await reopened.reload();
      expect(reopened.backupGeneration, 1);
    },
  );

  test('concurrent invalidations cannot reuse a session generation', () async {
    final prefs = await _prefs();
    final revisions = await Future.wait(
      List.generate(10, (_) => prefs.invalidateBackupSession()),
    );
    expect(revisions.toSet().length, 10);
    await prefs.reload();
    expect(prefs.backupGeneration, 10);
  });

  test(
    'logout blocks new work even if a caller captures the newest generation',
    () async {
      final prefs = await _prefs();
      await prefs.setBackupAccountBlocked(_instance.id, 7, true);
      final revision = await prefs.invalidateBackupSession();
      final context = BackupContext(
        instance: _instance,
        userId: 7,
        username: 'alice',
        token: 'test-only-token',
        settings: const BackupSettings(enabled: true, driveUuid: 'drive'),
        generation: revision,
      );
      expect(await isBackupContextActive(context), isFalse);
      final tokens = _Tokens();
      expect(
        await loadBackgroundAccount(prefs: prefs, secureStore: tokens),
        isNull,
      );
      expect(tokens.reads, isEmpty);
      await prefs.setBackupAccountBlocked(_instance.id, 7, false);
      expect(await isBackupContextActive(context), isTrue);
    },
  );

  test(
    'an in-flight context cannot outlive account switching or a new generation',
    () async {
      final prefs = await _prefs();
      final context = BackupContext(
        instance: _instance,
        userId: 7,
        username: 'alice',
        token: 'test-only-token',
        settings: const BackupSettings(enabled: true, driveUuid: 'drive'),
        generation: prefs.backupGeneration,
      );
      expect(await isBackupContextActive(context), isTrue);
      await prefs.setActiveAccount(_instance.id, 'bob');
      expect(await isBackupContextActive(context), isFalse);
      await prefs.setActiveAccount(_instance.id, 'alice');
      await prefs.invalidateBackupSession();
      expect(await isBackupContextActive(context), isFalse);
    },
  );

  test('background change cursors are isolated per account', () async {
    final prefs = await _prefs();
    await prefs.setAccountChangeCursor(_instance.id, 7, 'alice-cursor');
    expect(prefs.accountChangeCursor(_instance.id, 7), 'alice-cursor');
    expect(prefs.accountChangeCursor(_instance.id, 9), isNull);
  });
}
