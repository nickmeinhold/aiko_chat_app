/// Why an answered call stopped being held, and why a ring stopped ringing.
///
/// ## Why these exist
///
/// `claude-tasks#3591` gave the ring's ten REFUSALS names, and stopped at the
/// gate. Everything downstream of admission stayed dark — and on 2026-09-20 a
/// killed handset woke on a VoIP push, rang through CallKit, verified the
/// signature and ADMITTED the invitation in 4.9 seconds, then ended its own
/// system call 1.4 seconds later and joined nothing. The island log shows the
/// cold start in full and then silence: no room token was ever requested. The
/// caller sat in an empty room saying *"Waiting for the other person to
/// join…"*.
///
/// The app's entire record of that was ONE line, `call.ring.started`. Every
/// door past the gate — the three ways `_tryJoin` can decline to join,
/// `_release`, `stopRinging`, `CallScreen`'s unconditional teardown — wrote
/// nothing, so a perfect ring and a ring that died 1.4s later produced
/// byte-identical evidence.
///
/// These enums are the same move that turned `reason=stale` into
/// `ageMs=4913`: make the deciding branch say which branch it was.
library;

/// The fate of an answer the navigator was holding.
///
/// Every terminal exit of `_tryJoin` (and the deadline that bounds it) maps to
/// exactly one of these. [joined] is the positive control: without it, silence
/// would mean both "it worked" and "the logger never ran".
enum AnswerOutcome {
  /// The room was opened. The only outcome that is not a lost call.
  joined,

  /// No system-call bridge — calling is gated off in this build. Unreachable
  /// today (the same gate stops the VoIP token registering at all), kept
  /// because the two gates protect against different orders of a future edit.
  noBridge,

  /// Auth RESOLVED with nobody signed in, so this call can never be joined.
  ///
  /// Should be unreachable after an admitted ring — admission reads the same
  /// user two lines earlier in `_consider` — which is exactly why it is worth a
  /// line. An "impossible" branch that fires silently is how four hours go.
  signedOut,

  /// Already in a live call. CallKit models one call
  /// (`maximumCallsPerCallGroup = 1`) and so does this app.
  alreadyInLiveCall,

  /// A newer answer displaced this one. Conservation of ownership: nothing this
  /// navigator stops holding is ever simply dropped.
  displaced,

  /// The hold deadline elapsed with no admitted invitation — nothing was sent,
  /// the gate refused it, or the websocket never came back.
  neverAdmitted,

  /// The user pressed the red button in the system UI before the session was
  /// ready. The call is already over; joining now would open a call they left.
  endedInSystemUi,
}

/// Why the in-app ring stopped.
///
/// [callerHungUp] is the one that cost the most to NOT have: an admitted hangup
/// stops the ring through a path that wrote nothing, so it was indistinguishable
/// from a ring that simply vanished.
enum RingStopCause {
  /// An admitted call-END for this invitation arrived. The caller hung up.
  callerHungUp,

  /// Answered on the in-app banner.
  answeredInApp,

  /// Answered in the system call UI; the banner is silenced so it cannot paint
  /// over the call it just opened.
  answeredInSystemUi,

  /// Declined on the in-app banner.
  declined,

  /// The in-app ring window elapsed. NOT a decision about the call — the
  /// CallKit ring answers to a ceiling the island owns, and can still be
  /// ringing when this fires (design 16 v2 §3). Distinguishing it from a
  /// decision is most of why this enum is worth having.
  windowElapsed,

  /// Answered while a spent call screen was still mounted — the banner pops it
  /// and lets the answer through a turn later.
  answeredOverSpentCall,
}
