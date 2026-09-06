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
///  1. ~~The pre-connect disclosure.~~ **DONE.** Media is still routed through
///     the island's SFU in the clear (forced-relay, no `e2eeOptions`) — that has
///     not changed and is not going to without media E2EE — but the user is now
///     TOLD, which is what Decision 9d actually required. The indicator is on
///     the ring banner (before the callee answers) and on the call screen from
///     its first frame (before media flows). See
///     `features/call/domain/media_confidentiality.dart`.
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
