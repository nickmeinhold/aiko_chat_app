/// The sign-in providers the gateway advertises via `GET /v1/auth/providers`.
///
/// Wire shape: `{"providers": [{"slug","display_name","kind"}]}` where `kind`
/// is `native` (a compiled-in SDK flow — Apple/Google) or `broker` (the
/// server-side OAuth2 code flow — GitHub and future Discord/MS/etc).
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

  factory AuthProviderInfo.fromJson(Map<String, dynamic> json) =>
      AuthProviderInfo(
        slug: json['slug'] as String,
        displayName: json['display_name'] as String,
        // Unknown/missing kinds fall back to broker — a future kind we don't
        // recognise is more safely driven as a generic web flow than dropped.
        kind: json['kind'] == 'native'
            ? AuthProviderKind.native
            : AuthProviderKind.broker,
      );
}
