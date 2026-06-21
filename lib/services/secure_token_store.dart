import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../features/auth/domain/auth_models.dart';

/// Durable, encrypted store for the JWT pair — the single source of truth for
/// credentials. Both the REST auth interceptor and the WSS connect read tokens
/// through the [TokenProvider], which is backed by this.
class SecureTokenStore {
  static const _kAccess = 'aiko_access_token';
  static const _kRefresh = 'aiko_refresh_token';

  final FlutterSecureStorage _storage;

  SecureTokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  Future<AuthTokens?> read() async {
    final access = await _storage.read(key: _kAccess);
    final refresh = await _storage.read(key: _kRefresh);
    if (access == null || refresh == null) return null;
    return AuthTokens(accessToken: access, refreshToken: refresh);
  }

  Future<void> write(AuthTokens tokens) async {
    await _storage.write(key: _kAccess, value: tokens.accessToken);
    await _storage.write(key: _kRefresh, value: tokens.refreshToken);
  }

  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }
}
