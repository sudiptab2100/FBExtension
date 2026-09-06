import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/constants.dart';
import '../../data/models/ld_instance.dart';

/// Non-secret app preferences: the saved server list, the active instance, the
/// per-instance admin view-mode, theme mode, and background change cursors.
class Prefs {
  Prefs(this._prefs);

  final SharedPreferences _prefs;

  static Future<Prefs> create() async =>
      Prefs(await SharedPreferences.getInstance());

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

  Future<void> writeJson(String key, Map<String, dynamic> value) =>
      _prefs.setString(key, jsonEncode(value));
}
