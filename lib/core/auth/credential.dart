/// The values that cross between the session vault, its doors, and the two
/// consumers that present an access token (the REST interceptor and the WSS
/// connect).
library;

/// An access token, stamped with the session it was issued under.
///
/// The stamp is what lets a refresh tell "this token expired" apart from
/// "this token's session is gone". A request born under account A, retried
/// after a sign-in as account B, must not come back with B's token: a plain
/// string can't say which session it came from (PR #452, round 3).
final class Credential {
  final String accessToken;

  /// The vault's lease when this was issued: design 26's "generation". It
  /// advances on a NEW session (a sign-in) and on an end (a sign-out or a
  /// rejection), never on a refresh, which is the same session. Not the
  /// island JWT's `gen` claim.
  final int lease;

  const Credential(this.accessToken, this.lease);

  // A credential reaching a log must not carry the token with it.
  @override
  String toString() => 'Credential(lease $lease)';
}

/// Thrown by a remote-refresh function when the refresh token is *definitively
/// rejected* (HTTP 401/403) — i.e. the session is truly unauthenticated. Any
/// OTHER error (network/timeout/5xx) must propagate as-is so it's treated as
/// transient (retry later), NOT a logout. This distinction is what stops a
/// network blip from logging the user out (design 02).
class RefreshRejected implements Exception {
  const RefreshRejected();
}

/// The session a credential was issued under has ended or been replaced while
/// its refresh was asked for or in flight. The caller's work belongs to a
/// session that no longer exists: it fails, and is NOT a logout (the session
/// that replaced it is fine) and NOT a retry under the new session.
class SessionSuperseded implements Exception {
  const SessionSuperseded();

  @override
  String toString() => 'SessionSuperseded';
}

/// A sign-in for one island found a live session for another island in the
/// vault. Only a switch, which signs out first, may replace it (design 26
/// §2e; the switch's own atomicity is #447's).
class SessionHeldElsewhere implements Exception {
  const SessionHeldElsewhere();

  @override
  String toString() => 'SessionHeldElsewhere';
}

/// A successful `/v1/auth/refresh`. [refreshToken] is the rotated token when
/// the island rotates (island #420), or null from an island that predates
/// rotation — in which case the token we presented stays current.
class RefreshResult {
  final String accessToken;
  final String? refreshToken;

  const RefreshResult(this.accessToken, {this.refreshToken});

  factory RefreshResult.fromJson(Map<String, dynamic> j) => RefreshResult(
    j['access_token'] as String,
    refreshToken: j['refresh_token'] as String?,
  );
}
