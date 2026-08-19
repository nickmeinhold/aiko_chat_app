/// Auth domain types (Phase 1).
///
/// Wire shapes (verified against gateway rest/auth.py):
///   register/login -> {access_token, refresh_token, user: UserView}
///   refresh        -> {access_token}   (refresh token NOT rotated)
///   me / UserView  -> {user_id, username, display_name, aiko_username, is_moderator}
library;

/// The authenticated app user.
class AppUser {
  final String userId;
  final String username;
  final String displayName;
  final String aikoUsername;

  /// Whether this island considers the user a moderator — the island-global flag
  /// the gateway emits on `/v1/me` (`is_moderator`, sourced from its configured
  /// moderator set). PRESENTATION-ONLY: it shows/hides the operator UI; the true
  /// gate is server-side (`ModeratorUser`), so a stale/forged `true` grants no
  /// authority, only a door that 403s. Defaults false — fail-closed, so an older
  /// gateway that omits the field never accidentally exposes the operator seat.
  final bool isModerator;

  const AppUser({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.aikoUsername,
    this.isModerator = false,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
    userId: j['user_id'] as String,
    username: (j['username'] as String?) ?? '',
    displayName: (j['display_name'] as String?) ?? '',
    aikoUsername: (j['aiko_username'] as String?) ?? '',
    isModerator: (j['is_moderator'] as bool?) ?? false,
  );

  /// Serialize for local persistence (offline-first session restore). Keys
  /// mirror [fromJson] / the gateway UserView wire shape EXACTLY so a persisted
  /// user round-trips through [AppUser.fromJson] unchanged.
  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'display_name': displayName,
    'aiko_username': aikoUsername,
    'is_moderator': isModerator,
  };

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.userId == userId &&
      other.username == username &&
      other.displayName == displayName &&
      other.aikoUsername == aikoUsername &&
      other.isModerator == isModerator;

  @override
  int get hashCode =>
      Object.hash(userId, username, displayName, aikoUsername, isModerator);
}

/// JWT pair. The access token is short-lived (~15min); the refresh token is
/// long-lived and is NOT rotated on refresh, so it persists across refreshes.
class AuthTokens {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({required this.accessToken, required this.refreshToken});

  /// From a register/login response (carries both tokens).
  factory AuthTokens.fromJson(Map<String, dynamic> j) => AuthTokens(
    accessToken: j['access_token'] as String,
    refreshToken: j['refresh_token'] as String,
  );

  /// Apply a `/auth/refresh` response — only the access token changes; the
  /// existing refresh token is preserved (the gateway does not rotate it).
  AuthTokens withRefreshedAccess(String newAccessToken) =>
      AuthTokens(accessToken: newAccessToken, refreshToken: refreshToken);

  @override
  bool operator ==(Object other) =>
      other is AuthTokens &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(accessToken, refreshToken);
}

/// Result of a successful login/register: the user plus their tokens.
class AuthSession {
  final AppUser user;
  final AuthTokens tokens;

  const AuthSession({required this.user, required this.tokens});

  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
    user: AppUser.fromJson((j['user'] as Map).cast<String, dynamic>()),
    tokens: AuthTokens.fromJson(j),
  );
}
