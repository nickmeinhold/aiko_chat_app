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
/// reaches a live peer. Two things it owes the user do not:
///
///  1. **The pre-connect disclosure.** Media is routed through the island's SFU
///     in the clear (forced-relay, no `e2eeOptions`), and both this tab and the
///     island tab recorded a decision that the user is told so BEFORE a call
///     connects. Nothing tells them. Shipping the button without it ships a
///     promise we did not keep.
///  2. **A ring that reaches a closed app.** CallKit is designed, not built, so
///     an invitation to a backgrounded app is silence — and a caller has no way
///     to know that is what happened.
///
/// So the store build closes every door into calling rather than deleting the
/// code behind them: dev and test builds pass the define and keep exercising the
/// feature while the two gaps are closed.
const kCallingEnabled = bool.fromEnvironment('ENABLE_CALLING');

/// [kCallingEnabled] as a provider, so a test can override it and drive BOTH
/// configurations. A bare `const` read at three call sites would make the
/// shipped state the only testable one, and "calling is unreachable" would be a
/// claim no test could ever fail on.
final callingEnabledProvider = Provider<bool>((ref) => kCallingEnabled);
