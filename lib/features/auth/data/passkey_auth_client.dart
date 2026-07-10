/// The passkey (WebAuthn / FIDO2) sign-in seam — the app's sole ingress.
///
/// A passkey carries NO bearer secret: the device holds a
/// private key, the gateway stores only the matching PUBLIC key, and sign-in is
/// a challenge–signature. A gateway DB dump is therefore worthless, and the flow
/// is phishing-resistant by construction (the OS binds each passkey to the
/// `webcredentials:` associated domain and refuses to release it to any other
/// origin). That domain binding is why this path needs the Associated Domains
/// entitlement + a hosted apple-app-site-association / assetlinks.json.
///
/// This client owns ONLY the on-device authenticator leg. The WebAuthn structure
/// is opaque to it: the gateway issues `options` JSON, the platform authenticator
/// turns it into an attestation/assertion, and this client hands the resulting
/// JSON straight back for the gateway to verify. The `*.fromJsonString` /
/// `*.toJsonString` types already speak standard WebAuthn JSON, so there is no
/// bespoke serialization — only the platform call and the cancellation mapping.
///
/// We drive [PasskeysPlatform.instance] (from `passkeys_platform_interface`)
/// DIRECTLY rather than the `passkeys` umbrella package. The umbrella declares a
/// vestigial `ua_client_hints` dependency that lacks macOS Swift Package Manager
/// support and would force a CocoaPods fallback on the macOS target; the
/// implementation packages (`passkeys_darwin`/`passkeys_android`) pull no such
/// dep and self-register the platform instance via their `dartPluginClass`. The
/// only behaviour we replicate from the umbrella's wrapper is the cancellation
/// mapping (the rest — base64url pre-validation, the debug doctor — we don't
/// need: the gateway issues valid options and we never run in debug-doctor mode).
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:passkeys_platform_interface/passkeys_platform_interface.dart';
import 'package:passkeys_platform_interface/types/types.dart';

import 'auth_exceptions.dart' show AuthCeremonyCancelled, AuthCeremonyFailed;

/// Drives the on-device authenticator for the two WebAuthn legs. Each method
/// takes the gateway's `options` JSON (the `start` response) and returns the
/// authenticator's response JSON to be POSTed to the matching `finish` endpoint.
abstract interface class PasskeyAuthClient {
  /// Create a new passkey for the relying party described by [optionsJson]
  /// (WebAuthn `PublicKeyCredentialCreationOptions`). Returns the attestation
  /// response as WebAuthn JSON. Throws [AuthCeremonyCancelled] if the user
  /// dismisses the system sheet (silent restore) or [AuthCeremonyFailed] for
  /// any real authenticator/device error.
  Future<String> register(String optionsJson);

  /// Assert an existing passkey for [optionsJson] (WebAuthn
  /// `PublicKeyCredentialRequestOptions`). Returns the assertion response as
  /// WebAuthn JSON. Same cancellation/failure contract as [register].
  Future<String> authenticate(String optionsJson);
}

/// The real client, backed by the federated [PasskeysPlatform] instance.
class PlatformPasskeyAuthClient implements PasskeyAuthClient {
  PasskeysPlatform get _platform => PasskeysPlatform.instance;

  @override
  Future<String> register(String optionsJson) async {
    try {
      await _platform.cancelCurrentAuthenticatorOperation();
      final request = RegisterRequestType.fromJsonString(optionsJson);
      final response = await _platform.register(request);
      return response.toJsonString();
    } on PlatformException catch (e) {
      _throwMapped(e);
    } catch (e) {
      // The contract promises AuthCeremonyFailed for any real failure. A
      // non-PlatformException (e.g. fromJsonString choking on malformed options,
      // or a package-internal error) must not propagate raw to the UI.
      throw AuthCeremonyFailed('Passkey: $e');
    }
  }

  @override
  Future<String> authenticate(String optionsJson) async {
    try {
      await _platform.cancelCurrentAuthenticatorOperation();
      final request = AuthenticateRequestType.fromJsonString(optionsJson);
      final response = await _platform.authenticate(request);
      return response.toJsonString();
    } on PlatformException catch (e) {
      _throwMapped(e);
    } catch (e) {
      throw AuthCeremonyFailed('Passkey: $e');
    }
  }

  /// The platform authenticators surface a user dismissal as the
  /// [PlatformException] code `cancelled` on BOTH iOS and Android — map it to
  /// the SHARED silent cancellation so the controller restores prior state with
  /// no error banner. Everything else (`no-credentials-available`,
  /// `domain-not-associated`, `deviceNotSupported`, timeouts) is a real failure
  /// the UI surfaces, so the user can be nudged toward registration.
  Never _throwMapped(PlatformException e) => throw (e.code == 'cancelled'
      ? const AuthCeremonyCancelled()
      : AuthCeremonyFailed('Passkey: ${e.code}'));
}
