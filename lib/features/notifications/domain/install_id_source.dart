/// WHICH HANDSET this install is on — the missing fact that keeps a call
/// drawing two notifications.
///
/// ## What this is for
///
/// A dual-registered iPhone is TWO rows island-side: an alert token from UIKit
/// and a VoIP token from PushKit, minted by independent registries, neither
/// derivable from the other. A call invite fans out to both, so one call rings
/// CallKit *and* draws an "Incoming call / Tap to join" banner.
///
/// The island ships that duplicate ON PURPOSE. Its `plan_deliveries` states the
/// fork and the ruling in its own words — *"a duplicate notification is a
/// blemish; a missed call is the bug"* — and its safety argument is a property
/// of the code path rather than of the rows: the send-to-everything arm
/// suppresses nothing, so it cannot silently fail to deliver whatever mix of
/// kinds the tables hold.
///
/// Suppression needs to know the two rows share a screen. That is this value,
/// and until it exists the banner is correct behaviour rather than a bug to be
/// filed.
///
/// ## Why this is a SOURCE and not a field on [PushTokenSource]
///
/// The two token sources must report the SAME id or the grouping is worse than
/// absent — it would split one handset in two, and nothing anywhere would say
/// so. A per-source field makes disagreement representable; one shared source
/// makes it unconstructable. The same argument `VoipTokenSource` gives for
/// borrowing the APNs channel's `apnsEnvironment` rather than growing its own:
/// two copies of one fact is the drift shape this repo keeps paying for.
///
/// ## Why null is a first-class answer
///
/// Null means *"this platform has no honest answer"*, and it is the state the
/// whole app is in today. `registerDevice` omits the field, the island stores
/// NULL, and every behaviour is exactly what shipped before this existed. A
/// synthesised fallback would be strictly worse than nothing: it would assert a
/// handset identity nothing established, which is the one claim this field may
/// never make, and a wrong grouping costs a ring rather than a banner.
abstract class InstallIdSource {
  /// This handset's stable, device-bound id, or null where there is none to
  /// give.
  ///
  /// The contract the island's validator enforces at the boundary
  /// (`RegisterDeviceReq.install_id`): non-empty, at most 64 characters, and
  /// matching `^[A-Za-z0-9_.:-]+$`. A violation is a 422 that fails the ENTIRE
  /// registration, not just this field — so an implementation that cannot meet
  /// it must return null rather than its best effort.
  Future<String?> installId();
}
