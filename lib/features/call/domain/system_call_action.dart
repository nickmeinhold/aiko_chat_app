/// What the platform's own call UI did (claude-tasks#4420).
///
/// "System call" rather than "CallKit": the same two transitions are what
/// Android's ConnectionService / full-screen intent will report (design 12
/// Decision 8), and the Dart half above this has no business knowing which
/// platform answered. The vocabulary is the seam's, not Apple's.
library;

/// The transitions the platform call UI can report. **A closed set** — the wire
/// carries the name as a string across a platform channel and this enum is where
/// that string stops being one.
enum SystemCallActionKind {
  /// The user answered. On a locked handset this is a swipe on the full-screen
  /// ring, and the app may not even have finished launching.
  answered,

  /// The call is over — the user pressed the red button in the system UI, or the
  /// OS tore the call down. **NOT necessarily the user**, and the distinction is
  /// one this layer cannot make: `CXEndCallAction` says a call ended and never
  /// says who ended it (claude-tasks#4278, where a label asserting an actor the
  /// callback cannot observe produced a confident wrong reading).
  ended;

  /// Parse a name off the platform channel, or null if it is not one of ours.
  ///
  /// **Null is a real answer, not a failure to handle.** A newer native half can
  /// emit a member this build has never heard of, and the honest response is to
  /// ignore it rather than to crash or to guess at the nearest neighbour — the
  /// same permissive-decode obligation `CallKitRinger.handle` carries in the
  /// other direction (design 16 v2 §7c).
  static SystemCallActionKind? parse(String? name) {
    for (final k in SystemCallActionKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// One transition, and the channel it happened to.
///
/// **The channel is the only identity there is.** The VoIP payload is
/// `{"aps": …, "c": <channel>, "k": <kind>}` — there is no call id on the wire
/// (island design 14 would add one and is undecided), the SFU room IS the
/// channel, and so the channel is what a join and a teardown are both keyed on.
class SystemCallAction {
  const SystemCallAction({
    required this.kind,
    required this.channelId,
    this.origin,
  });

  final SystemCallActionKind kind;
  final String channelId;

  /// WHICH native event produced this — diagnostic only, never branched on.
  ///
  /// `ended` covers two events that mean opposite things and were
  /// indistinguishable here until 2026-09-20:
  ///
  ///  - `endAction` — a `CXEndCallAction`: somebody or something ENDED the
  ///    call. The lock-screen red button, or a hangup we reported.
  ///  - `providerReset` — `providerDidReset`: the system tore our provider
  ///    down and every call with it. Nobody ended anything; the OS stopped
  ///    believing in our calls.
  ///
  /// Both used to arrive as a bare `ended`, so a handset that rang, was never
  /// answered, and lost its call 2.1s later produced a report that could not
  /// say whether a person had hung up or iOS had reclaimed us. Deliberately a
  /// free-form string and deliberately not part of [kind]: the ACTIONS are a
  /// closed vocabulary the app branches on, and this is provenance for a
  /// reader. Null from any producer that does not say (every older build, and
  /// every test that does not care).
  final String? origin;

  @override
  String toString() =>
      'SystemCallAction(${kind.name}, $channelId${origin == null ? '' : ', $origin'})';

  @override
  bool operator ==(Object other) =>
      other is SystemCallAction &&
      other.kind == kind &&
      other.channelId == channelId &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(kind, channelId, origin);
}
