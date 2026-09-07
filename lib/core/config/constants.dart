/// App-wide constants: API paths, defaults, storage keys, and mDNS service types.
///
/// Keep this in sync with LocalDrive-Master's server (`docs/http-api.md`,
/// `src/server/discovery.ts`). All API paths are relative to an instance base URL.
class Api {
  Api._();

  // ---- Auth ----------------------------------------------------------------
  static const login = '/api/auth/login';
  static const register = '/api/auth/register';
  static const logout = '/api/auth/logout';
  static const me = '/api/auth/me';
  static const authConfig = '/api/auth/config';

  // ---- Drives --------------------------------------------------------------
  static const drives = '/api/drives';
  static const drivesRequestAccess = '/api/drives/request-access';
  static const drivesAll = '/api/drives/all';
  static const drivesRegister = '/api/drives/register';
  static const drivesUnregister = '/api/drives/unregister';
  static const drivesRegisterFolder = '/api/drives/register-folder';

  // ---- Files ---------------------------------------------------------------
  static const filesList = '/api/files/list';
  static const filesMkdir = '/api/files/mkdir';
  static const filesRename = '/api/files/rename';
  static const filesMove = '/api/files/move';
  static const filesCopy = '/api/files/copy';
  static const filesDelete = '/api/files/delete';
  static const filesDownload = '/api/files/download';
  static const filesRaw = '/api/files/raw';
  static const filesZip = '/api/files/zip';
  static const filesThumb = '/api/files/thumb';

  // ---- Uploads (tus) -------------------------------------------------------
  static const upload = '/api/upload';
  static const backupUploads = '/api/backup/uploads';

  // ---- Search / stats ------------------------------------------------------
  static const search = '/api/search';
  static const stats = '/api/stats';
  static const activity = '/api/stats/activity';

  // ---- Admin ---------------------------------------------------------------
  static const users = '/api/users';
  static const userAcls = '/api/users/acls';
  static const access = '/api/access';
  static const config = '/api/config';
  static const serverStart = '/api/server/start';
  static const serverStop = '/api/server/stop';
  static const serverRestart = '/api/server/restart';

  // ---- Events (SSE) --------------------------------------------------------
  static const events = '/api/events'; // admin-wide live events
  static const eventsUser = '/api/events/user'; // user-scoped (server addition)
  static const changes = '/api/changes'; // background polling (server addition)

  // ---- Utility -------------------------------------------------------------
  static const health = '/api/health';
  static const cert = '/api/cert';
  static const connect = '/api/connect';
}

class Defaults {
  Defaults._();
  static const int httpPort = 4820;
  static const int httpsPort = 4843;
  static const String appName = 'LocalDrive';
  static const String orgId = 'com.sudiptab2100.localdrive_app';
}

/// mDNS/Bonjour service types the app browses to discover servers.
class Discovery {
  Discovery._();

  /// Dedicated LocalDrive service (server addition) — most reliable.
  static const String serviceType = '_localdrive._tcp';

  /// Generic HTTP service; filtered by advertised name "LocalDrive".
  static const String httpServiceType = '_http._tcp';

  static const String advertisedName = 'LocalDrive';
}

/// Keys for secure storage + shared_preferences. Tokens are namespaced per
/// instance so multiple servers can be signed in at once.
class StoreKeys {
  StoreKeys._();
  static const savedInstances = 'ld.instances';
  static const activeInstanceId = 'ld.active_instance';
  static const viewModePrefix = 'ld.view_mode.'; // + instanceId
  static const tokenPrefix = 'ld.token.'; // secure; + instanceId (legacy)
  // Multi-account (per server): a token is stored per (instance, username) so
  // several users can stay signed in on the same server and switch instantly.
  static const userTokenSep = '::'; // secure key: ld.token.<instanceId>::<user>
  static const accountsPrefix =
      'ld.accounts.'; // prefs; + instanceId -> [Account]
  static const activeAccountPrefix =
      'ld.active_account.'; // prefs; + instanceId
  static const themeMode = 'ld.theme_mode';
  static const backupSettings = 'ld.backup_settings';
  static const backupProfilePrefix = 'ld.backup_profile.';
  static const backupGeneration = 'ld.backup_generation';
  static const legacyBackupOwner = 'ld.legacy_backup_owner';
  static const backgroundError = 'ld.background_error';
  static const backupAttemptPrefix = 'ld.backup_attempt.';
  static const backupBlockedPrefix = 'ld.backup_blocked.';
  static const lastChangeCursor = 'ld.change_cursor.'; // + instanceId
}

/// The admin view-mode cookie understood by the server's `scope.ts`.
class ViewCookie {
  ViewCookie._();
  static const name = 'ld_view';
  static const admin = 'admin'; // whole share (all users' spaces)
  static const user = 'user'; // own space only
}

/// Local-notification channel identity (Android) and notification id ranges.
class Notif {
  Notif._();
  static const String channelId = 'localdrive_changes';
  static const String channelName = 'LocalDrive activity';
  static const String channelDesc =
      'File changes, access approvals and backup status';
  static const String backupChannelId = 'localdrive_backup';
  static const String backupChannelName = 'LocalDrive backup';
}

/// Background task identities. These must match the iOS
/// `BGTaskSchedulerPermittedIdentifiers` entries in `ios/Runner/Info.plist`.
class BgTasks {
  BgTasks._();
  static const String refresh = 'com.sudiptab2100.localdrive_app.refresh';
  static const String backup = 'com.sudiptab2100.localdrive_app.backup';

  /// Minimum WorkManager/BGTask period (the OS floor is 15 minutes).
  static const Duration minPeriod = Duration(minutes: 15);
}

/// Extra shared_preferences keys for notifications + backup toggles.
class SettingKeys {
  SettingKeys._();
  static const notificationsEnabled = 'ld.notifications_enabled';
}
