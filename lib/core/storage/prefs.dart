import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../../data/models/account.dart';
import '../../data/models/backup_settings.dart';
import '../../data/models/ld_instance.dart';
import 'backup_keys.dart';

/// Non-secret app preferences: the saved server list, the active instance, the
/// per-instance admin view-mode, theme mode, and background change cursors.
class Prefs {
  Prefs(this._prefs);

  final SharedPreferences _prefs;
  static Future<void> _revisionLock = Future<void>.value();

  static Future<Prefs> create() async =>
      Prefs(await SharedPreferences.getInstance());

  Future<void> reload() => _prefs.reload();

  // ---- Saved instances -----------------------------------------------------
  List<LdInstance> readInstances() {
    final raw = _prefs.getString(StoreKeys.savedInstances);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => LdInstance.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> writeInstances(List<LdInstance> instances) {
    final raw = jsonEncode(instances.map((e) => e.toJson()).toList());
    return _prefs.setString(StoreKeys.savedInstances, raw);
  }

  // ---- Active instance -----------------------------------------------------
  String? get activeInstanceId => _prefs.getString(StoreKeys.activeInstanceId);

  Future<void> setActiveInstanceId(String? id) async {
    if (id == null) {
      await _prefs.remove(StoreKeys.activeInstanceId);
    } else {
      await _prefs.setString(StoreKeys.activeInstanceId, id);
    }
  }

  // ---- Admin view mode (per instance) -------------------------------------
  String viewMode(String instanceId) =>
      _prefs.getString('${StoreKeys.viewModePrefix}$instanceId') ??
      ViewCookie.admin;

  Future<void> setViewMode(String instanceId, String mode) =>
      _prefs.setString('${StoreKeys.viewModePrefix}$instanceId', mode);

  // ---- Accounts registry (per instance) -----------------------------------
  // The non-secret list of signed-in accounts for a server (the token itself
  // lives in SecureStore). Enables the in-app user switcher.
  List<Account> accounts(String instanceId) {
    final raw = _prefs.getString('${StoreKeys.accountsPrefix}$instanceId');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Account.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> writeAccounts(String instanceId, List<Account> list) {
    final key = '${StoreKeys.accountsPrefix}$instanceId';
    if (list.isEmpty) return _prefs.remove(key);
    return _prefs.setString(
      key,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  String? activeAccount(String instanceId) =>
      _prefs.getString('${StoreKeys.activeAccountPrefix}$instanceId');

  Future<void> setActiveAccount(String instanceId, String? username) async {
    final key = '${StoreKeys.activeAccountPrefix}$instanceId';
    if (username == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, username);
    }
  }

  Future<void> clearAccounts(String instanceId) async {
    await _prefs.remove('${StoreKeys.accountsPrefix}$instanceId');
    await _prefs.remove('${StoreKeys.activeAccountPrefix}$instanceId');
  }

  // ---- Account-owned backup configuration ---------------------------------
  BackupSettings readBackupSettings(String instanceId, int userId) {
    final raw = _prefs.getString(
      '${StoreKeys.backupProfilePrefix}${backupProfileKey(instanceId, userId)}',
    );
    if (raw == null) return const BackupSettings();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The saved backup configuration is invalid.');
    }
    return BackupSettings.fromJson(decoded);
  }

  Future<void> writeBackupSettings(
    String instanceId,
    int userId,
    BackupSettings settings,
  ) async {
    await writeJson(
      '${StoreKeys.backupProfilePrefix}${backupProfileKey(instanceId, userId)}',
      settings.toJson(),
    );
  }

  bool get hasUnclaimedLegacyBackup =>
      _prefs.containsKey(StoreKeys.backupSettings) &&
      !_prefs.containsKey(StoreKeys.legacyBackupOwner);

  BackupSettings? get legacyBackupSettings {
    final json = readJson(StoreKeys.backupSettings);
    return json == null ? null : BackupSettings.fromJson(json);
  }

  Future<void> markLegacyBackupClaimed(String instanceId, int userId) async {
    if (!await _prefs.setString(
      StoreKeys.legacyBackupOwner,
      backupProfileKey(instanceId, userId),
    )) {
      throw StateError('Could not save the backup migration choice.');
    }
  }

  int get backupGeneration => _prefs.getInt(StoreKeys.backupGeneration) ?? 0;

  bool backupAccountBlocked(String instanceId, int userId) =>
      _prefs.getBool(
        '${StoreKeys.backupBlockedPrefix}${backupProfileKey(instanceId, userId)}',
      ) ??
      false;

  Future<void> setBackupAccountBlocked(
    String instanceId,
    int userId,
    bool blocked,
  ) async {
    if (!await _prefs.setBool(
      '${StoreKeys.backupBlockedPrefix}${backupProfileKey(instanceId, userId)}',
      blocked,
    )) {
      throw StateError(
        'Could not save the account background-work restriction.',
      );
    }
  }

  Future<int> invalidateBackupSession() async {
    final previous = _revisionLock;
    final release = Completer<void>();
    _revisionLock = release.future;
    await previous;
    try {
      await reload();
      final next = backupGeneration + 1;
      if (!await _prefs.setInt(StoreKeys.backupGeneration, next)) {
        throw StateError('Could not pause the previous backup session.');
      }
      return next;
    } finally {
      release.complete();
    }
  }

  DateTime? backupAttempt(String profileId) {
    final raw = _prefs.getString('${StoreKeys.backupAttemptPrefix}$profileId');
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setBackupAttempt(String profileId, DateTime at) async {
    if (!await _prefs.setString(
      '${StoreKeys.backupAttemptPrefix}$profileId',
      at.toUtc().toIso8601String(),
    )) {
      throw StateError('Could not record the backup attempt.');
    }
  }

  String? get backgroundError => _prefs.getString(StoreKeys.backgroundError);

  Future<void> setBackgroundError(String? message) async {
    final saved = message == null
        ? await _prefs.remove(StoreKeys.backgroundError)
        : await _prefs.setString(StoreKeys.backgroundError, message);
    if (!saved) throw StateError('Could not save background task status.');
  }

  String? accountChangeCursor(String instanceId, int userId) =>
      _prefs.getString(
        '${StoreKeys.lastChangeCursor}${backupProfileKey(instanceId, userId)}',
      );

  Future<void> setAccountChangeCursor(
    String instanceId,
    int userId,
    String cursor,
  ) async {
    if (!await _prefs.setString(
      '${StoreKeys.lastChangeCursor}${backupProfileKey(instanceId, userId)}',
      cursor,
    )) {
      throw StateError('Could not save the account change cursor.');
    }
  }

  // ---- Theme mode ----------------------------------------------------------
  String get themeMode => _prefs.getString(StoreKeys.themeMode) ?? 'system';
  Future<void> setThemeMode(String mode) =>
      _prefs.setString(StoreKeys.themeMode, mode);

  // ---- Notifications -------------------------------------------------------
  bool get notificationsEnabled =>
      _prefs.getBool(SettingKeys.notificationsEnabled) ?? true;
  Future<void> setNotificationsEnabled(bool value) =>
      _prefs.setBool(SettingKeys.notificationsEnabled, value);

  // ---- Background change cursor (per instance) ----------------------------
  String? changeCursor(String instanceId) =>
      _prefs.getString('${StoreKeys.lastChangeCursor}$instanceId');
  Future<void> setChangeCursor(String instanceId, String iso) =>
      _prefs.setString('${StoreKeys.lastChangeCursor}$instanceId', iso);

  // ---- Generic JSON blobs (e.g. backup settings) --------------------------
  Map<String, dynamic>? readJson(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    if (!await _prefs.setString(key, jsonEncode(value))) {
      throw StateError('Could not save app preferences.');
    }
  }
}
