/// The OAuth-broker sign-in seam (GitHub and future Discord/MS/etc).
///
/// Unlike the native [SocialAuthClient] (Apple/Google SDK → `id_token`), broker
/// providers have no native SDK: the gateway runs the whole OAuth2 code dance in
/// a browser and hands back a single-use HANDOFF code. This client owns only
/// that browser leg — open `/v1/auth/oauth/{slug}/start`, let the system auth
/// session run the flow, and capture the `aikochat://auth?code=…` redirect. The
/// handoff is then redeemed at `POST /v1/auth/oauth/exchange` (in the REST seam),
/// which returns the SAME [SocialOutcome] as the native path — so everything
/// downstream is shared.
///
/// We use [FlutterWebAuth2] (ASWebAuthenticationSession on iOS, Custom Tabs on
/// Android) with a custom callback SCHEME rather than Universal/App Links: it's
/// Apple's recommended OAuth-in-app primitive, needs no associated-domains
/// entitlement or hosted AASA/assetlinks, and auto-dismisses on the redirect.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'social_auth_client.dart' show SocialSignInCancelled, SocialSignInFailed;

/// The custom URL scheme the gateway redirects the broker callback to
/// (`aikochat://auth?code=…`). Must match the gateway's `app_oauth_callback_url`
/// and the Android manifest callback activity's `<data android:scheme>`.
const String kAikoCallbackScheme = 'aikochat';

/// The host segment of the callback (`aikochat://auth`). Validated on the way
/// back so only the advertised callback authority is accepted.
const String _callbackHost = 'auth';

/// The result of a broker web flow: the single-use handoff [code] PLUS the
/// app-held [verifier] that must be presented at `/exchange`. The verifier never
/// leaves the app, so a [code] intercepted via a hijacked custom scheme is
/// useless without it (cage-match #37).
typedef BrokerHandoff = ({String code, String verifier});

/// Drives a gateway broker provider to a single-use handoff.
abstract interface class BrokerAuthClient {
  /// Run the broker web flow for [slug] (e.g. `github`). Returns the handoff
  /// (code + verifier), or throws [SocialSignInCancelled] (user dismissed the
  /// browser) / [SocialSignInFailed] (provider/transport error). The handoff is
  /// single-use and short-lived — redeem it immediately via `/exchange`.
  Future<BrokerHandoff> authenticate(String slug);
}

/// Generate a high-entropy app verifier (32 random bytes, base64url-nopad).
String _generateVerifier() {
  final rnd = Random.secure();
  final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The S256 challenge for [verifier] — base64url(sha256(verifier)). MUST match
/// the gateway's `pkce.app_challenge_for` (sha256 over the verifier's ASCII).
String _challengeFor(String verifier) =>
    base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');

class WebAuthBrokerClient implements BrokerAuthClient {
  /// The gateway HTTP base (e.g. `https://chat.imagineering.cc`).
  final String httpBaseUrl;

  /// The callback scheme; overridable for tests.
  final String callbackScheme;

  const WebAuthBrokerClient({
    required this.httpBaseUrl,
    this.callbackScheme = kAikoCallbackScheme,
  });

  @override
  Future<BrokerHandoff> authenticate(String slug) async {
    // Bind this flow to the app (cage-match #37): the challenge crosses the wire
    // to /start; the verifier stays here and is presented only at /exchange.
    final verifier = _generateVerifier();
    final challenge = _challengeFor(verifier);
    // challenge is base64url-nopad (URL-safe: -, _, no padding) → safe unescaped.
    final url =
        '$httpBaseUrl/v1/auth/oauth/$slug/start?app_challenge=$challenge';
    final String result;
    try {
      result = await FlutterWebAuth2.authenticate(
        url: url,
        callbackUrlScheme: callbackScheme,
      );
    } on PlatformException catch (e) {
      // flutter_web_auth_2 surfaces a user dismissal as code 'CANCELED' on both
      // platforms — map it to the silent-restore cancellation, everything else
      // is a real failure.
      if (e.code == 'CANCELED') {
        throw const SocialSignInCancelled();
      }
      throw SocialSignInFailed('Broker: ${e.message ?? e.code}');
    }

    // Enforce the advertised callback authority (cage-match Carnot P2): only the
    // exact aikochat://auth shape is accepted, not "any URL flutter_web_auth_2
    // hands back". Reduces callback-confusion inside the auth session (it is NOT
    // a fix for scheme hijack on its own — that's the verifier binding).
    final uri = Uri.parse(result);
    if (uri.scheme != callbackScheme || uri.host != _callbackHost) {
      throw SocialSignInFailed(
          'Broker: unexpected callback ${uri.scheme}://${uri.host}');
    }
    final params = uri.queryParameters;
    // The gateway returns EITHER ?code=<handoff> (success) OR ?error=<class>
    // (coarse, non-sensitive). Never a token in the URL (broker design).
    final error = params['error'];
    if (error != null) {
      throw SocialSignInFailed('Broker: $error');
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const SocialSignInFailed('Broker: callback had no handoff code');
    }
    return (code: code, verifier: verifier);
  }
}
