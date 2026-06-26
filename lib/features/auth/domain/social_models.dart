/// Social sign-in domain types.
///
/// Wire shapes (the contract both the app and gateway build to):
///   POST /v1/auth/social {provider, id_token, nonce, name?} ->
///     returning identity -> {access_token, refresh_token, user}  (== login)
///     NEW identity        -> {status: "pending", provisioning_token,
///                              suggested_name?, email?}
///   POST /v1/auth/social/claim {provisioning_token, handle, display_name} ->
///     {access_token, refresh_token, user}   (409 if handle taken)
library;

import 'auth_models.dart';

/// The result of verifying a provider token at the gateway. Either the identity
/// is already linked to an account ([Authenticated] — proceed exactly like a
/// password login), or it's brand new and must claim a handle first
/// ([PendingHandle]).
sealed class SocialOutcome {
  const SocialOutcome();
}

/// The provider identity is known — full session, log straight in.
class Authenticated extends SocialOutcome {
  final AuthSession session;
  const Authenticated(this.session);
}

/// A new provider identity. The gateway has verified the human but has not yet
/// created an app account — the app must collect a handle + display name and
/// call `claimHandle`. The [provisioningToken] authorises that one call;
/// [suggestedName]/[email] pre-fill the form when the provider supplied them.
class PendingHandle extends SocialOutcome {
  final String provisioningToken;
  final String? suggestedName;
  final String? email;

  const PendingHandle({
    required this.provisioningToken,
    this.suggestedName,
    this.email,
  });
}
