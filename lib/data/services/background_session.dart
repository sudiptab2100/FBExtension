import 'package:collection/collection.dart';

import '../../core/storage/prefs.dart';
import '../../core/storage/secure_store.dart';
import '../models/backup_context.dart';
import '../models/ld_instance.dart';

class BackgroundAccount {
  const BackgroundAccount({
    required this.instance,
    required this.userId,
    required this.username,
    required this.token,
    required this.generation,
  });

  final LdInstance instance;
  final int userId;
  final String username;
  final String token;
  final int generation;
}

Future<BackgroundAccount?> loadBackgroundAccount({
  Prefs? prefs,
  SecureStore? secureStore,
  String? instanceId,
}) async {
  final storage = prefs ?? await Prefs.create();
  await storage.reload();
  final id = instanceId ?? storage.activeInstanceId;
  if (id == null) return null;
  final instance = storage.readInstances().firstWhereOrNull(
    (value) => value.id == id,
  );
  final username = storage.activeAccount(id);
  if (instance == null || username == null) return null;
  final account = storage
      .accounts(id)
      .firstWhereOrNull((value) => value.username == username);
  final userId = account?.userId;
  if (userId == null || userId <= 0) {
    await storage.setBackgroundError(
      'Open LocalDrive and sign in to confirm the backup account.',
    );
    return null;
  }
  if (storage.backupAccountBlocked(id, userId)) return null;
  final generation = storage.backupGeneration;
  final token = await (secureStore ?? SecureStore()).readUserToken(
    id,
    username,
  );
  final resolved = BackgroundAccount(
    instance: instance,
    userId: userId,
    username: username,
    token: token ?? '',
    generation: generation,
  );
  if (!await isBackgroundAccountCurrent(
    resolved,
    prefs: storage,
    requireActiveInstance: instanceId == null,
  )) {
    return null;
  }
  if (token == null || token.isEmpty) {
    await storage.setBackgroundError(
      'Sign in again to allow background work for the selected account.',
    );
    return null;
  }
  return resolved;
}

Future<bool> isBackgroundAccountCurrent(
  BackgroundAccount account, {
  Prefs? prefs,
  bool requireActiveInstance = false,
}) async {
  final storage = prefs ?? await Prefs.create();
  await storage.reload();
  final instanceId = account.instance.id;
  return storage.backupGeneration == account.generation &&
      (!requireActiveInstance || storage.activeInstanceId == instanceId) &&
      storage.readInstances().any((instance) => instance.id == instanceId) &&
      !storage.backupAccountBlocked(instanceId, account.userId) &&
      storage.activeAccount(instanceId) == account.username &&
      storage
          .accounts(instanceId)
          .any(
            (saved) =>
                saved.userId == account.userId &&
                saved.username == account.username,
          );
}

Future<BackupContext?> loadBackupContext({Prefs? prefs}) async {
  final storage = prefs ?? await Prefs.create();
  final account = await loadBackgroundAccount(prefs: storage);
  if (account == null) return null;
  return BackupContext(
    instance: account.instance,
    userId: account.userId,
    username: account.username,
    token: account.token,
    generation: account.generation,
    settings: storage.readBackupSettings(account.instance.id, account.userId),
  );
}

Future<bool> isBackupContextActive(BackupContext context) async {
  final prefs = await Prefs.create();
  await prefs.reload();
  return prefs.backupGeneration == context.generation &&
      !prefs.backupAccountBlocked(context.instance.id, context.userId) &&
      prefs.activeInstanceId == context.instance.id &&
      prefs.activeAccount(context.instance.id) == context.username &&
      prefs
          .accounts(context.instance.id)
          .any(
            (account) =>
                account.userId == context.userId &&
                account.username == context.username,
          );
}
