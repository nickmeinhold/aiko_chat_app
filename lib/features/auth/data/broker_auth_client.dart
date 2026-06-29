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

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'social_auth_client.dart' show SocialSignInCancelled, SocialSignInFailed;

/// The custom URL scheme the gateway redirects the broker callback to
/// (`aikochat://auth?code=…`). Must match the gateway's `app_oauth_callback_url`
/// and the Android manifest callback activity's `<data android:scheme>`.
const String kAikoCallbackScheme = 'aikochat';

/// Drives a gateway broker provider to a single-use handoff code.
abstract interface class BrokerAuthClient {
  /// Run the broker web flow for [slug] (e.g. `github`). Returns the handoff
  /// code from the callback, or throws [SocialSignInCancelled] (user dismissed
  /// the browser) / [SocialSignInFailed] (provider/transport error). The handoff
  /// is single-use and short-lived — redeem it immediately via `/exchange`.
  Future<String> authenticate(String slug);
}

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
  Future<String> authenticate(String slug) async {
    final url = '$httpBaseUrl/v1/auth/oauth/$slug/start';
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

    final params = Uri.parse(result).queryParameters;
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
    return code;
  }
}
