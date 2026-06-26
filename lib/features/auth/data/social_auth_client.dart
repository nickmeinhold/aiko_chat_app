/// The social-sign-in seam. The native provider SDKs (Apple, Google) live
/// behind this interface so the auth controller is unit-testable without a
/// platform channel — mirroring the data layer's other seams ([ChatTransport],
/// [ChatRestApi]). The real implementation ([GatewaySocialAuthClient]) wraps the
/// SDKs; tests use a fake.
library;

/// The supported identity providers. The wire value (`provider.name`) — `apple`
/// / `google` — is what the gateway's `/v1/auth/social` endpoint expects.
enum SocialProvider { apple, google }

/// A provider credential captured on-device, ready to hand to the gateway.
///
/// [idToken] is the provider's OIDC ID token (a JWT) — the gateway verifies it
/// against the provider's JWKS. [rawNonce] is the UN-hashed nonce we generated:
/// the provider embeds `sha256(rawNonce)` in the token's `nonce` claim, and the
/// gateway re-derives and compares to defeat replay. [name] is the display name
/// the provider returned — Apple supplies it ONLY on the very first sign-in, so
/// it may be null on every subsequent one (the gateway must persist it then).
class SocialCredential {
  final SocialProvider provider;
  final String idToken;
  final String rawNonce;
  final String? name;

  const SocialCredential({
    required this.provider,
    required this.idToken,
    required this.rawNonce,
    this.name,
  });
}

/// The user backed out of the provider sheet. Not an error — the controller
/// restores the prior state silently (no error banner).
class SocialSignInCancelled implements Exception {
  const SocialSignInCancelled();
  @override
  String toString() => 'SocialSignInCancelled';
}

/// The provider flow failed before we could obtain a credential (missing ID
/// token, platform error). Distinct from a *cancellation*.
class SocialSignInFailed implements Exception {
  final String message;
  const SocialSignInFailed(this.message);
  @override
  String toString() => 'SocialSignInFailed($message)';
}

/// Drives a native provider flow to a verified [SocialCredential].
abstract interface class SocialAuthClient {
  /// Run the [provider] sign-in flow. Returns a credential, or throws
  /// [SocialSignInCancelled] (user backed out) / [SocialSignInFailed].
  Future<SocialCredential> signIn(SocialProvider provider);
}
