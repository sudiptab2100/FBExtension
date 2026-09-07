import '../../core/config/constants.dart';
import '../../core/storage/backup_keys.dart';
import 'backup_settings.dart';
import 'ld_instance.dart';

/// An immutable execution identity. The token must never be serialized.
class BackupContext {
  const BackupContext({
    required this.instance,
    required this.userId,
    required this.username,
    required this.token,
    required this.settings,
    this.generation = 0,
  });

  final LdInstance instance;
  final int userId;
  final String username;
  final String token;
  final BackupSettings settings;
  final int generation;

  String get profileId => backupProfileKey(instance.id, userId);

  Map<String, String> get headers => {
    'Authorization': 'Bearer $token',
    'Cookie': '${ViewCookie.name}=${ViewCookie.user}',
  };
}
