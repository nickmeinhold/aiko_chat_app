/// Auth domain types (Phase 1).
///
/// Wire shapes (verified against gateway rest/auth.py):
///   register/login -> {access_token, refresh_token, user: UserView}
///   refresh        -> {access_token}   (refresh token NOT rotated)
///   me / UserView  -> {user_id, username, display_name, aiko_username}
library;

/// The authenticated app user.
class AppUser {
  final String userId;
  final String username;
  final String displayName;
  final String aikoUsername;

  const AppUser({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.aikoUsername,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        userId: j['user_id'] as String,
        username: (j['username'] as String?) ?? '',
        displayName: (j['display_name'] as String?) ?? '',
        aikoUsername: (j['aiko_username'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is AppUser &&
      other.userId == userId &&
      other.username == username &&
      other.displayName == displayName &&
      other.aikoUsername == aikoUsername;

  @override
  int get hashCode => Object.hash(userId, username, displayName, aikoUsername);
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
