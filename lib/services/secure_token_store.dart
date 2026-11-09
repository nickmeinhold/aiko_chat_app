import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../features/auth/domain/auth_models.dart';

/// Durable, encrypted store for the JWT pair — the single source of truth for
/// credentials. Both the REST auth interceptor and the WSS connect read tokens
/// through the [TokenProvider], which is backed by this.
///
/// The pair is stored with the island that minted it (#436). The island the app
/// is ON lives in prefs, and iOS deletes prefs on an uninstall but keeps the
/// Keychain, so after a reinstall only this record can say where the tokens
/// belong. Guessing from "tokens exist" sent one island's refresh token to the
/// other (cage-match #439, all four seats).
class SecureTokenStore {
  static const _kAccess = 'aiko_access_token';
  static const _kRefresh = 'aiko_refresh_token';
  static const _kIsland = 'aiko_tokens_island';

  final FlutterSecureStorage _storage;

  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  Future<AuthTokens?> read() async {
    final access = await _storage.read(key: _kAccess);
    final refresh = await _storage.read(key: _kRefresh);
    if (access == null || refresh == null) return null;
    return AuthTokens(accessToken: access, refreshToken: refresh);
  }

  /// The island the stored tokens were minted on. Null for tokens an older
  /// build wrote, which recorded no island.
  Future<String?> readIsland() => _storage.read(key: _kIsland);

  /// The island is written FIRST, so tokens this build writes are never found
  /// without it.
  Future<void> write(AuthTokens tokens, {required String island}) async {
    await _storage.write(key: _kIsland, value: island);
    await _storage.write(key: _kAccess, value: tokens.accessToken);
    await _storage.write(key: _kRefresh, value: tokens.refreshToken);
  }

  /// The island is deleted LAST, for the same reason.
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kIsland);
  }
}
