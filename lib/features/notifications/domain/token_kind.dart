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

/// The island resolved a device registration to a kind other than the one this
/// client asked for — including an island too old to have an answer.
///
/// ## Why this is a refusal and not a warning
///
/// A VoIP token stored as an `alert` row is not a weaker ring, it is no ring:
/// the island sends an ordinary alert push to a PushKit token and the handset
/// stays silent for a call it was told about. Nothing downstream observes that.
/// The 201's echo is the only moment the two kinds are distinguishable, so it is
/// the only place the check can live.
///
/// ## What it does NOT mean
///
/// Not "the row was not written". The island answered, so it holds a row keyed
/// on this token — with semantics we did not ask for. The registrar's
/// ambiguous-landing tail is therefore the correct handler and not a fallback:
/// the unregister debt stays owed, and the pairing is deliberately NOT recorded
/// as registered, so the next session edge tries again rather than skipping a
/// device it believes is paired.
///
/// ## Carrying the fact, not the body
///
/// Both fields are enum values or null. This type never touches a response body,
/// a path, or a message, for the same reason [PushFailure] does not: the log
/// carries the FACT and the reader does no inference. `DeviceKindRefused(asked:
/// voip, resolved: alert)` closes a diagnosis that `error=DioException` cannot.
class DeviceKindRefused implements Exception {
  const DeviceKindRefused({
    required this.asked,
    required this.resolved,
    this.echoed = true,
  });

  /// The kind this client declared, from the token source.
  final TokenKind asked;

  /// The kind the island came back with, or null when it named a value this
  /// build has no model of.
  ///
  /// NULL IS NOT "ABSENT". An absent field is a resolved `alert` — that is the
  /// wire contract in both directions, and it is what keeps an alert
  /// registration working against an island built before the field existed.
  /// Null here means the island answered with a kind whose semantics we cannot
  /// name, which is not a thing to pair a token to.
  final TokenKind? resolved;

  /// Whether the island actually STATED a kind, as opposed to us inferring one
  /// from its silence.
  ///
  /// Without this, [resolved] destroys the distinction that matters most to a
  /// reader: an island that echoed `alert` and an island that said nothing both
  /// arrive here as [TokenKind.alert], and a log line would swear the island
  /// answered when the wire was quiet (Tesla + Carnot, round 1, reached
  /// independently). The inference is still the right one — absent means alert,
  /// which is what keeps an old island working — but a diagnosis needs to know
  /// it WAS an inference.
  final bool echoed;

  @override
  String toString() =>
      'DeviceKindRefused(asked: ${asked.wire}, '
      'resolved: ${resolved?.wire}, echoed: $echoed)';
}
