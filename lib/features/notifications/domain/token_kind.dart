/// Which DELIVERY SEMANTICS a push token carries, as distinct from which
/// transport issued it.
///
/// [DevicePlatform] answers "which service must the island talk to". This
/// answers "what does a push to this token DO when it arrives". They are
/// genuinely orthogonal axes and collapsing them is the mistake this type
/// exists to prevent: an `apns_voip` platform value would be a value Android
/// can structurally never hold, which is the tell that it is the wrong axis.
///
/// The island agrees, and it is the binding contract — its `TokenKind` is a
/// separate column with `server_default='alert'`, deliberately NOT a third
/// `Platform` member.
///
/// **ABSENT MEANS [alert] ON THE WIRE.** That is not a convenience default, it
/// is what makes the change need no migration and no backfill: every row and
/// every older client stays correct without being touched. It rests on a
/// measured fact rather than an assumption — no build has ever minted a VoIP
/// token, so a record with no kind IS an alert record.
///
/// A VoIP token needs NO user permission; an alert token needs granted
/// notification permission. So one handset holding a VoIP token and never an
/// alert token is a normal, permanent state — not an error, and not a
/// transitional one.
enum TokenKind {
  /// An ordinary remote-notification token. A push draws a banner.
  alert('alert'),

  /// A PushKit token. A push MUST be reported to CallKit before the delivery
  /// handler returns, or iOS terminates the app — and repeated failures make
  /// the system stop delivering VoIP pushes to this app on this device.
  voip('voip');

  const TokenKind(this.wire);

  /// The exact string the island's enum accepts. Load-bearing: an out-of-set
  /// value is rejected at its boundary, so these are asserted in tests rather
  /// than trusted to survive a rename.
  final String wire;

  /// Parse a stored or received value, defaulting to [alert].
  ///
  /// TOTAL, and never throws. It is read while decoding the unregister debt
  /// ledger, where a throw would be read as "nothing owed" and would silently
  /// discharge every outstanding obligation.
  static TokenKind fromWire(String? value) => switch (value) {
    'voip' => TokenKind.voip,
    _ => TokenKind.alert,
  };
}
