/// Identity-resolution domain types — the outcome of any gateway sign-in
/// ceremony (today: passkey register / authenticate).
///
/// The gateway's identity door returns ONE of two shapes, and both the app and
/// gateway build to this contract:
///   passkey finish ->
///     returning identity -> {access_token, refresh_token, user}  (== login)
///     NEW identity        -> {status: "pending", provisioning_token,
///                              suggested_name?, email?}
///   POST /v1/auth/social/claim {provisioning_token, handle, display_name} ->
///     {access_token, refresh_token, user}   (409 if handle taken)
///
/// (The `/social/claim` path is a gateway-owned endpoint name retained from the
/// removed social sign-in; it now serves the first-passkey-creates-account
/// handle claim.)
library;

import 'auth_models.dart';

/// The result of resolving an identity at the gateway. Either the identity is
/// already linked to an account ([Authenticated] — log straight in), or it's
/// brand new and must claim a handle first ([PendingHandle]).
sealed class IdentityOutcome {
  const IdentityOutcome();
}

/// The identity is known — full session, log straight in.
class Authenticated extends IdentityOutcome {
  final AuthSession session;
  const Authenticated(this.session);
}

/// A new identity. The gateway has verified the credential but has not yet
/// created an app account — the app must collect a handle + display name and
/// call `claimHandle`. The [provisioningToken] authorises that one call;
/// [suggestedName]/[email] pre-fill the form when the gateway supplied them.
class PendingHandle extends IdentityOutcome {
  final String provisioningToken;
  final String? suggestedName;
  final String? email;

  const PendingHandle({
    required this.provisioningToken,
    this.suggestedName,
    this.email,
  });
}
