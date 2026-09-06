/// Build-time capability gates.
///
/// A flag lives here only while a capability is BUILT but not yet OWED-IN-FULL —
/// the code is good, something the feature promises the user is missing. It is a
/// statement about what this build is allowed to offer, not a configuration
/// surface: nothing here is user-visible or runtime-settable.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether 1:1 A/V calling is reachable in this build. **Off unless
/// `--dart-define=ENABLE_CALLING=true`.**
///
/// Calling works — DM long-press → Call opens a LiveKit room and the ring
/// reaches a live peer. It owed the user two things. **One is now built:**
///
///  1. ~~The pre-connect disclosure.~~ **DONE.** Media still terminates at the
///     island's SFU, which decrypts it (forced-relay, no `e2eeOptions`) — that
///     has not changed and will not without media E2EE — but the user is now
///     TOLD, which is what Decision 9d actually required.
///
///     Two scope notes, both corrected in cage-match rather than discovered
///     later. It is NOT "in the clear": WebRTC mandates DTLS-SRTP, so the media
///     is encrypted on the wire and decrypted AT the island — the honest claim
///     is "not end-to-end encrypted", and the UI says exactly that. And "before
///     connect" holds for the CALLEE, who must press Answer with the warning on
///     the same surface; for the caller the indicator is concurrent with
///     connect, because an indicator cannot gate an action that has no gate.
///     See `features/call/domain/media_confidentiality.dart`.
///  2. **A ring that reaches a closed app.** CallKit is designed, not built, so
///     an invitation to a backgrounded app is silence — and a caller has no way
///     to know that is what happened. **This is now the only thing holding the
///     gate.**
///
/// So the store build still closes every door into calling rather than deleting
/// the code behind them: dev and test builds pass the define and keep exercising
/// the feature while the remaining gap is closed.
///
/// NOT a licence to flip this flag. Gap 2 is a capability the user cannot work
/// around and cannot even observe failing — silence is indistinguishable from
/// being ignored. And cross-island calling carries its own separate gate
/// (island design 13, Decision 9c / claude-tasks#3697), which this disclosure
/// satisfies one arm of but does not retire.
const kCallingEnabled = bool.fromEnvironment('ENABLE_CALLING');

/// [kCallingEnabled] as a provider, so a test can override it and drive BOTH
/// configurations. A bare `const` read at three call sites would make the
/// shipped state the only testable one, and "calling is unreachable" would be a
/// claim no test could ever fail on.
final callingEnabledProvider = Provider<bool>((ref) => kCallingEnabled);
