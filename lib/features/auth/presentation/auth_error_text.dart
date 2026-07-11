import '../../chat/data/chat_rest_api.dart'
    show
        HandleTaken,
        NetworkUnavailable,
        PasskeyAlreadyRegistered,
        Unauthorized;
import '../data/auth_exceptions.dart';

/// What the user was trying to do at the moment an auth failure occurred.
///
/// The SAME exception yields honest, context-appropriate copy: a
/// [NetworkUnavailable] while *creating* an account is the one irreducibly-online
/// moment (the passkey challenge is server-issued and the new public key must
/// reach the gateway), so we can honestly promise "after this, Aiko works
/// offline" — a promise the offline-first work (PR #71/#72) earned. The same
/// failure while *signing in* to an existing account, or *claiming a handle*, is
/// a different sentence.
enum AuthAction {
  /// Tapped "Create a passkey" — first-passkey-creates-account.
  createAccount,

  /// Tapped "Already have a passkey? Sign in".
  signIn,

  /// On the claim-handle screen, picking a public @handle for a new identity.
  claimHandle,
}

/// The single, centralised map from an auth failure to human-readable,
/// actionable text — shared by the login and claim-handle screens (it used to be
/// duplicated inline in each, drifting apart).
///
/// Design rules, in order:
///  1. DOMAIN exceptions match by TYPE (never by string) so transport detail
///     stays out of the UI — [NetworkUnavailable], [HandleTaken],
///     [PasskeyAlreadyRegistered], [Unauthorized].
///  2. Passkey ceremony failures arrive as `AuthCeremonyFailed('Passkey: <code>')`
///     (the shape [PlatformPasskeyAuthClient] emits); documented codes get
///     tailored guidance.
///  3. The FALLBACK surfaces the RAW text ("Sign-in failed: …"), never a blanket
///     "something went wrong" — so a brand-new failure mode is never invisible.
///     A blank error is the only case that gets the generic line. This
///     never-blind-again property is pinned by login_error_text_test.dart.
String authErrorText(
  Object? error, {
  required String host,
  required AuthAction action,
}) {
  // (1) Domain exceptions, matched by type.
  switch (error) {
    case NetworkUnavailable():
      switch (action) {
        case AuthAction.createAccount:
          return 'Creating your account needs internet just this once. '
              "Reconnect and we'll finish — after that, Aiko works offline.";
        case AuthAction.signIn:
          return "You're offline. Reconnect to sign in — Aiko works offline "
              "once you're in.";
        case AuthAction.claimHandle:
          return "You're offline. Reconnect to finish setting up your account.";
      }
    case HandleTaken():
      return "That handle is taken — try another. If it's already yours, sign in "
          'with your existing account, then add a passkey from Settings.';
    case PasskeyAlreadyRegistered():
      return 'That passkey is already registered to an account. Try '
          '"Already have a passkey? Sign in" instead.';
    case Unauthorized():
      // On the claim screen an Unauthorized is far more often a dead/expired
      // provisioning token than a passkey-verify failure (cage-match #74, Tesla).
      return action == AuthAction.claimHandle
          ? 'Your setup session expired. Start again to pick your handle.'
          : "We couldn't verify that passkey. Try again, or create a new one.";
  }

  // (2) Passkey ceremony failures: AuthCeremonyFailed('Passkey: <code>').
  final raw = error is AuthCeremonyFailed
      ? error.message
      : (error?.toString() ?? '');
  final lower = raw.toLowerCase();
  if (raw.contains('no-credentials-available')) {
    return 'No passkey found on this device. '
        'Tap "Create a passkey" above to make one.';
  }
  if (raw.contains('domain-not-associated')) {
    return "Passkeys aren't linked to $host yet, so sign-in can't complete. "
        "(The server's domain association is still pending.)";
  }
  if (raw.contains('deviceNotSupported') || lower.contains('not supported')) {
    return "This device doesn't support passkeys.";
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return 'The request timed out. Please try again.';
  }

  // (3) Fallback: never hide a new failure mode behind the generic line, but
  // name the RIGHT ritual — an unmapped claim failure must not read "Sign-in
  // failed" (cage-match #74, Carnot + Tesla). A blank error is the only case
  // that gets the generic line.
  final prefix = switch (action) {
    AuthAction.createAccount => "Couldn't create your account",
    AuthAction.signIn => 'Sign-in failed',
    AuthAction.claimHandle => "Couldn't finish setup",
  };
  return raw.isEmpty
      ? 'Something went wrong. Please try again.'
      : '$prefix: $raw';
}

/// The host (with port when present) of a gateway base URL for display — falls
/// back to the full URL if it doesn't parse to a host. Shared by every screen
/// that shows the active gateway or passes `host:` to [authErrorText], so the
/// login and claim screens can never drift on how a gateway is named
/// (cage-match #74, Tesla: two tunings of one host seam). The port is
/// load-bearing: two gateways differing only by port would otherwise be
/// indistinguishable (Carnot, cage-match #53).
String gatewayHostLabel(String httpBaseUrl) {
  final uri = Uri.tryParse(httpBaseUrl);
  final host = uri?.host;
  if (host == null || host.isEmpty) return httpBaseUrl;
  return uri!.hasPort ? '$host:${uri.port}' : host;
}
