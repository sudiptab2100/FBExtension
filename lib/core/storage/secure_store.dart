import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/constants.dart';

/// Secure storage for JWT bearer tokens (Keychain / Keystore).
///
/// Tokens are namespaced per (instance, username) so multiple users can stay
/// signed in on the same server at once and be switched without re-login. The
/// legacy per-instance key (`ld.token.<instanceId>`) is still read/deleted for
/// one-time migration into the multi-account layout.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _accountOptions = IOSOptions(accessibility: null);
  static const _backgroundChannel = MethodChannel('localdrive/bg_upload');

  // ---- Legacy single-token-per-instance (migration only) ------------------
  String _tokenKey(String instanceId) => '${StoreKeys.tokenPrefix}$instanceId';

  Future<String?> readToken(String instanceId) =>
      _storage.read(key: _tokenKey(instanceId));

  Future<void> writeToken(String instanceId, String token) =>
      _storage.write(key: _tokenKey(instanceId), value: token);

  Future<void> deleteToken(String instanceId) =>
      _storage.delete(key: _tokenKey(instanceId));

  // ---- Per-user tokens (current) ------------------------------------------
  String _userTokenKey(String instanceId, String username) =>
      '${StoreKeys.tokenPrefix}$instanceId${StoreKeys.userTokenSep}$username';

  Future<String?> readUserToken(String instanceId, String username) =>
      _storage.read(
        key: _userTokenKey(instanceId, username),
        iOptions: _accountOptions,
      );

  Future<void> writeUserToken(
    String instanceId,
    String username,
    String token,
  ) => _storage.write(
    key: _userTokenKey(instanceId, username),
    value: token,
    iOptions: _accountOptions,
  );

  /// Update protection atomically; rewriting a value does not migrate Keychain
  /// accessibility in flutter_secure_storage.
  Future<void> setBackgroundAccess(
    String instanceId,
    String username, {
    required bool enabled,
  }) async {
    if (!Platform.isIOS) return;
    await _backgroundChannel.invokeMethod<void>('setTokenBackgroundAccess', {
      'key': _userTokenKey(instanceId, username),
      'enabled': enabled,
    });
  }

  Future<void> deleteUserToken(String instanceId, String username) =>
      _storage.delete(key: _userTokenKey(instanceId, username));

  /// Remove every stored token for an instance (legacy + all listed users).
  /// Called when a server is removed from the app.
  Future<void> deleteInstanceTokens(
    String instanceId,
    Iterable<String> usernames,
  ) async {
    await deleteToken(instanceId);
    for (final u in usernames) {
      await deleteUserToken(instanceId, u);
    }
  }
}
