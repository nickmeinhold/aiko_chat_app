/// Which APNs world a push token belongs to, in THE ISLAND'S VOCABULARY.
///
/// TWO VOCABULARIES FOR ONE FACT, and they do not agree. Apple's
/// `aps-environment` entitlement says `development` / `production`; the island's
/// closed set says `sandbox` / `production` (verified against the deployed
/// `/openapi.json` and `devices_service.py`, not the design note). The half that
/// collides is the half that matches — `production` means the same thing on both
/// sides, so passing Apple's string straight through LOOKS correct until a debug
/// build sends `development`, fails the island's DB CHECK, and 422s the entire
/// registration. That is strictly worse than the silence this field exists to
/// remove, so the translation lives at the boundary in [fromApsEnvironment] and
/// there is deliberately no way to construct one of these from a raw wire string.
///
/// The underlying fact: a token minted by a development build is valid ONLY
/// against `api.sandbox.push.apple.com`; a TestFlight or App Store build's token
/// ONLY against `api.push.apple.com`. The strings are indistinguishable, the
/// wrong host answers a bare `400 BadDeviceToken`, and no marking on the token
/// lets the island infer it — which is why the client must declare it.
///
/// The island resolves an OMITTED value from its own `APNS_USE_SANDBOX` (`true`
/// on both boxes), so until we declare it a TestFlight handset registers a
/// production token against a sandbox-defaulted island and simply never rings
/// (claude-tasks#3450, island #3386).
enum PushEnvironment {
  /// `api.sandbox.push.apple.com` — tokens from a locally-signed development
  /// build. Apple calls this environment `development`.
  sandbox('sandbox'),

  /// `api.push.apple.com` — tokens from a TestFlight or App Store build.
  production('production');

  const PushEnvironment(this.wire);

  /// The exact string the island's `PushEnvironment` enum accepts, which drives
  /// a DB CHECK on `device_tokens.push_environment`. Never derive this from
  /// [name] — they agree today and a rename would send a value that fails the
  /// constraint, and the island fails CLOSED on a bad value by design.
  final String wire;

  /// Translate Apple's `aps-environment` entitlement value.
  ///
  /// Anything unrecognised — including null, and including a future Apple value
  /// — resolves to null, which the island reads as "use my default". Null is the
  /// one answer with a defined meaning on the far side; a guess here would put a
  /// 422 on the register path and fail the whole registration rather than
  /// degrading one field.
  static PushEnvironment? fromApsEnvironment(String? apsEnvironment) =>
      switch (apsEnvironment) {
        'development' => PushEnvironment.sandbox,
        'production' => PushEnvironment.production,
        _ => null,
      };
}
