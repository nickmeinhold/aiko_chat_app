/// The passkey (WebAuthn / FIDO2) sign-in seam — the third ingress alongside the
/// native [SocialAuthClient] (Apple/Google SDK → id_token) and the
/// [BrokerAuthClient] (OAuth2 code → handoff).
///
/// Unlike those two, a passkey carries NO bearer secret: the device holds a
/// private key, the gateway stores only the matching PUBLIC key, and sign-in is
/// a challenge–signature. A gateway DB dump is therefore worthless, and the flow
/// is phishing-resistant by construction (the OS binds each passkey to the
/// `webcredentials:` associated domain and refuses to release it to any other
/// origin). That domain binding is why this path needs the Associated Domains
/// entitlement + a hosted apple-app-site-association / assetlinks.json — the cost
/// the custom-scheme broker deliberately avoided.
///
/// This client owns ONLY the on-device authenticator leg. The WebAuthn structure
/// is opaque to it: the gateway issues `options` JSON, the platform authenticator
/// (iOS `AuthenticationServices`, Android `Credential Manager`, via the `passkeys`
/// package) turns it into an attestation/assertion, and this client hands the
/// resulting JSON straight back for the gateway to verify. The package's
/// `*.fromJsonString` / `*.toJsonString` already speak standard WebAuthn JSON, so
/// there is no bespoke serialization here — only the platform call and the
/// cancellation mapping.
library;

import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import 'social_auth_client.dart' show SocialSignInCancelled, SocialSignInFailed;

/// Drives the on-device authenticator for the two WebAuthn legs. Each method
/// takes the gateway's `options` JSON (the `start` response) and returns the
/// authenticator's response JSON to be POSTed to the matching `finish` endpoint.
abstract interface class PasskeyAuthClient {
  /// Create a new passkey for the relying party described by [optionsJson]
  /// (WebAuthn `PublicKeyCredentialCreationOptions`). Returns the attestation
  /// response as WebAuthn JSON. Throws [SocialSignInCancelled] if the user
  /// dismisses the system sheet (silent restore, like the other ingresses) or
  /// [SocialSignInFailed] for any real authenticator/device error.
  Future<String> register(String optionsJson);

  /// Assert an existing passkey for [optionsJson] (WebAuthn
  /// `PublicKeyCredentialRequestOptions`). Returns the assertion response as
  /// WebAuthn JSON. Same cancellation/failure contract as [register].
  Future<String> authenticate(String optionsJson);
}

/// The real client, backed by the `passkeys` package's [PasskeyAuthenticator].
class PlatformPasskeyAuthClient implements PasskeyAuthClient {
  final PasskeyAuthenticator _authenticator;

  PlatformPasskeyAuthClient({PasskeyAuthenticator? authenticator})
      : _authenticator = authenticator ?? PasskeyAuthenticator();

  @override
  Future<String> register(String optionsJson) async {
    try {
      final request = RegisterRequestType.fromJsonString(optionsJson);
      final response = await _authenticator.register(request);
      return response.toJsonString();
    } on PasskeyAuthCancelledException {
      throw const SocialSignInCancelled();
    } on AuthenticatorException catch (e) {
      throw SocialSignInFailed('Passkey: ${e.runtimeType}');
    }
  }

  @override
  Future<String> authenticate(String optionsJson) async {
    try {
      final request = AuthenticateRequestType.fromJsonString(optionsJson);
      final response = await _authenticator.authenticate(request);
      return response.toJsonString();
    } on PasskeyAuthCancelledException {
      throw const SocialSignInCancelled();
    } on AuthenticatorException catch (e) {
      // Includes NoCredentialsAvailableException (no passkey on this device) and
      // DomainNotAssociatedException (AASA/entitlement mismatch) — both are real
      // failures the UI surfaces, not silent cancellations.
      throw SocialSignInFailed('Passkey: ${e.runtimeType}');
    }
  }
}
