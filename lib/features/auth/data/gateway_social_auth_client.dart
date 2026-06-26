import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'social_auth_client.dart';

/// The real [SocialAuthClient]: drives the native Apple/Google SDKs on-device
/// and returns the provider ID token for the gateway to verify.
///
/// Nonce handling differs by provider and is encoded here deliberately:
///   - **Apple** hashes the nonce — we pass `sha256(rawNonce)` and Apple echoes
///     that hash in the token's `nonce` claim.
///   - **Google** echoes the nonce VERBATIM — we pass `rawNonce` (at
///     initialize-time, per google_sign_in v7) and it lands unchanged.
/// Either way we send the gateway the RAW nonce; the gateway applies the
/// provider-appropriate transform before comparing.
///
/// Provider IDs are PUBLIC (not secrets) and injected at build time:
///   --dart-define=GOOGLE_SERVER_CLIENT_ID=...apps.googleusercontent.com
///   --dart-define=GOOGLE_IOS_CLIENT_ID=...apps.googleusercontent.com   (iOS)
/// Apple needs none here — the bundle id is the audience for the native flow.
class GatewaySocialAuthClient implements SocialAuthClient {
  static const _googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
  static const _googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  @override
  Future<SocialCredential> signIn(SocialProvider provider) => switch (provider) {
        SocialProvider.apple => _apple(),
        SocialProvider.google => _google(),
      };

  Future<SocialCredential> _apple() async {
    final rawNonce = _newNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
      final idToken = cred.identityToken;
      if (idToken == null) {
        throw const SocialSignInFailed('Apple returned no identity token');
      }
      // Apple sends the name only on the FIRST sign-in; null on later ones.
      final name = [cred.givenName, cred.familyName]
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .join(' ');
      return SocialCredential(
        provider: SocialProvider.apple,
        idToken: idToken,
        rawNonce: rawNonce,
        name: name.isEmpty ? null : name,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const SocialSignInCancelled();
      }
      throw SocialSignInFailed('Apple: ${e.message}');
    }
  }

  Future<SocialCredential> _google() async {
    final rawNonce = _newNonce();
    try {
      await GoogleSignIn.instance.initialize(
        clientId: _googleIosClientId.isEmpty ? null : _googleIosClientId,
        serverClientId:
            _googleServerClientId.isEmpty ? null : _googleServerClientId,
        nonce: rawNonce, // Google echoes this verbatim into the id_token.
      );
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const SocialSignInFailed('Google returned no ID token');
      }
      return SocialCredential(
        provider: SocialProvider.google,
        idToken: idToken,
        rawNonce: rawNonce,
        name: account.displayName,
      );
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const SocialSignInCancelled();
      }
      throw SocialSignInFailed('Google sign-in failed (${e.code.name})');
    }
  }

  /// A fresh 256-bit URL-safe nonce per sign-in (replay defence).
  static String _newNonce() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
