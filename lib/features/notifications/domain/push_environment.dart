/// Which APNs host will accept the tokens this build mints.
///
/// A token minted under `development` is valid ONLY against
/// `api.sandbox.push.apple.com`; one minted by a TestFlight or App Store build
/// is valid ONLY against `api.push.apple.com`. The two token strings are
/// indistinguishable — same length, same alphabet — and the wrong host answers
/// a bare `400 BadDeviceToken` with no other clue. The island deliberately does
/// NOT reap on `BadDeviceToken` for exactly this reason, so getting it wrong
/// costs silence rather than data.
///
/// The island resolves an OMITTED value from its own `APNS_USE_SANDBOX`, which
/// is `true` on both boxes. That default is right for a debug build off a Mac
/// and wrong for every distribution build, which is why declaring it is not an
/// optimisation: until we send this, a TestFlight handset registers a
/// production token against a sandbox island and simply never rings
/// (claude-tasks#3450, island #3386).
enum PushEnvironment {
  /// Sandbox — tokens from a locally-signed development build.
  development('development'),

  /// Production — tokens from a TestFlight or App Store build.
  production('production');

  const PushEnvironment(this.wire);

  /// The exact string the island's enum accepts; an out-of-set value is a 422
  /// at its boundary. Never derive this from [name] — they agree today and a
  /// rename would silently start sending a value the island rejects.
  final String wire;

  /// Parse a value handed up from the platform channel, or null if it is
  /// absent or unrecognised.
  ///
  /// An unrecognised value resolves to null rather than a guess, because null
  /// is the one answer with a defined island-side meaning (fall back to
  /// `APNS_USE_SANDBOX`). Guessing here would put a 422 on the register path,
  /// which fails the whole registration rather than degrading one field.
  static PushEnvironment? fromWire(String? wire) {
    for (final value in PushEnvironment.values) {
      if (value.wire == wire) return value;
    }
    return null;
  }
}
