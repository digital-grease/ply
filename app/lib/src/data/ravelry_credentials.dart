import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The user's own Ravelry credentials (access key + personal/read-only key) plus their cached
/// username. Never bundled with the app — the user enters their own.
class RavelryCreds {
  const RavelryCreds({required this.accessKey, required this.key, required this.username});
  final String accessKey;
  final String key;
  final String username;
}

/// Stores [RavelryCreds] in the platform keystore (Android Keystore / iOS Keychain) via
/// flutter_secure_storage — credentials never sit in plaintext in app storage. The [FlutterSecureStorage]
/// is injectable for tests.
class RavelryCredentials {
  RavelryCredentials({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kAccess = 'ravelry_access_key';
  static const _kKey = 'ravelry_key';
  static const _kUser = 'ravelry_username';

  Future<RavelryCreds?> load() async {
    final a = await _storage.read(key: _kAccess);
    final k = await _storage.read(key: _kKey);
    final u = await _storage.read(key: _kUser);
    if (a == null || k == null || a.isEmpty || k.isEmpty) return null;
    return RavelryCreds(accessKey: a, key: k, username: u ?? '');
  }

  Future<void> save(RavelryCreds creds) async {
    await _storage.write(key: _kAccess, value: creds.accessKey);
    await _storage.write(key: _kKey, value: creds.key);
    await _storage.write(key: _kUser, value: creds.username);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kKey);
    await _storage.delete(key: _kUser);
  }
}
