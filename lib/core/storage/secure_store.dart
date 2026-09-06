import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/constants.dart';

/// Secure, per-instance storage for JWT bearer tokens (Keychain / Keystore).
class SecureStore {
  SecureStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _tokenKey(String instanceId) => '${StoreKeys.tokenPrefix}$instanceId';

  Future<String?> readToken(String instanceId) =>
      _storage.read(key: _tokenKey(instanceId));

  Future<void> writeToken(String instanceId, String token) =>
      _storage.write(key: _tokenKey(instanceId), value: token);

  Future<void> deleteToken(String instanceId) =>
      _storage.delete(key: _tokenKey(instanceId));
}
