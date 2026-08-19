/// Which push service issued a device token, and therefore which service the
/// island must talk to in order to wake that handset.
///
/// THIS IS A TRANSPORT, NOT AN OPERATING SYSTEM. The distinction matters because
/// the obvious shortcut — one Firebase SDK on both platforms, since Firebase
/// will relay to APNs for you — collapses these two values into one and makes
/// the enum pointless. We take tokens from each service DIRECTLY: on Apple
/// platforms the raw APNs device token, on Android the FCM registration token.
///
/// The reason is not purity. On iOS, Apple is already a mandatory intermediary
/// — there is no third-party push on the platform, and a suspended app can only
/// be woken through APNs. Relaying iOS pushes through Firebase adds Google as a
/// SECOND intermediary on the one platform where we had no choice about the
/// first, and buys nothing but a smaller diff. On a product whose thesis is
/// sovereignty that is the wrong trade, and it is invisible once made.
///
/// Mirrors the island's closed `Platform` set, which drives a DB CHECK on
/// `device_tokens.platform` — an out-of-set value is a 422 at its boundary, so
/// the wire strings here are load-bearing and are asserted in
/// `device_platform_test.dart` rather than trusted to survive a rename.
///
/// A future self-hosted transport (UnifiedPush on Android, which would take
/// Google out of that path entirely) is a new value here plus a new value in
/// the island's enum and its migration — deliberately cheap, because the
/// discriminator already exists. See claude-tasks#3267.
enum DevicePlatform {
  apns('apns'),
  fcm('fcm');

  const DevicePlatform(this.wire);

  /// The exact string the island's `Platform` enum accepts. Never derive this
  /// from [name] — they agree today and a rename would silently start sending
  /// a value the island rejects at the boundary.
  final String wire;
}
