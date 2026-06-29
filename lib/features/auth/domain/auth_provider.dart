/// The sign-in providers the gateway advertises via `GET /v1/auth/providers`.
///
/// Wire shape: `{"providers": [{"slug","display_name","kind"}]}` where `kind`
/// is `native` (a compiled-in SDK flow — Apple/Google), `broker` (the
/// server-side OAuth2 code flow — GitHub and future Discord/MS/etc), or
/// `passkey` (a WebAuthn/FIDO2 flow — usernameless, no third party).
///
/// This is what lets "add a broker provider" be a GATEWAY-only change: the app
/// renders a generic button for any `broker` entry and drives the same web-auth
/// flow by slug, so a new broker provider needs no app release. Native providers
/// still need their SDK compiled in, so the app maps those slugs to the specific
/// native buttons it ships.
library;

/// How a provider is driven on-device.
enum AuthProviderKind {
  /// A compiled-in native SDK (Apple, Google) → `POST /v1/auth/social`.
  native,

  /// The server-side OAuth2 code broker (GitHub, …) → web-auth → `/exchange`.
  broker,

  /// A WebAuthn/FIDO2 passkey → device authenticator → `/passkey/*` (no third
  /// party, no stored secret). Usernameless: one advertised entry drives both
  /// "sign in with a passkey" and "create a passkey".
  passkey,
}

/// One advertised sign-in option.
class AuthProviderInfo {
  /// Stable wire id — `apple`, `google`, `github`, … Used as the broker path
  /// segment (`/v1/auth/oauth/{slug}/start`) and to map native slugs to SDKs.
  final String slug;

  /// Human label for the button ("GitHub").
  final String displayName;

  final AuthProviderKind kind;

  const AuthProviderInfo({
    required this.slug,
    required this.displayName,
    required this.kind,
  });

  /// Parse one advertised provider, or null if its `kind` isn't one this app
  /// build understands. FAIL-CLOSED (cage-match Carnot P2): `kind` is a closed
  /// set at the app↔gateway boundary, so an unrecognised future kind (`saml`,
  /// `disabled`, …) must be DROPPED, not coerced into a flow the app would then
  /// drive against the wrong endpoint — behaviour that was never negotiated. The
  /// caller filters out the nulls.
  static AuthProviderInfo? tryParse(Map<String, dynamic> json) {
    final kind = switch (json['kind']) {
      'native' => AuthProviderKind.native,
      'broker' => AuthProviderKind.broker,
      'passkey' => AuthProviderKind.passkey,
      _ => null,
    };
    if (kind == null) return null;
    final slug = json['slug'];
    final displayName = json['display_name'];
    if (slug is! String || displayName is! String) return null;
    return AuthProviderInfo(slug: slug, displayName: displayName, kind: kind);
  }
}
