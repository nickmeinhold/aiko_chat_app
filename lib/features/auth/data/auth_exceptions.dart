/// Shared exceptions for an on-device sign-in ceremony.
///
/// A "ceremony" is any interactive ingress that drives a system sheet the user
/// can dismiss — today that means the passkey (WebAuthn) flow. These types are
/// deliberately ceremony-AGNOSTIC: the controller distinguishes a silent
/// user-dismissal ([AuthCeremonyCancelled] → restore prior state, no banner)
/// from a real failure ([AuthCeremonyFailed] → surface the reason), and that
/// distinction is identical regardless of which authenticator raised it.
///
/// (They previously lived in the now-removed social-sign-in seam under the
/// `SocialSignIn*` names, which mislabelled every passkey error as "social".)
library;

/// The user backed out of the system sheet. Not an error — the controller
/// restores the prior state silently (no error banner).
class AuthCeremonyCancelled implements Exception {
  const AuthCeremonyCancelled();
  @override
  String toString() => 'AuthCeremonyCancelled';
}

/// The ceremony failed before it could produce a credential (a real
/// authenticator/device error). Distinct from a *cancellation* — the UI
/// surfaces [message].
class AuthCeremonyFailed implements Exception {
  final String message;
  const AuthCeremonyFailed(this.message);
  @override
  String toString() => 'AuthCeremonyFailed($message)';
}
