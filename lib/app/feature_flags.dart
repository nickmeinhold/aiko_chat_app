/// Build-time capability gates.
///
/// A flag lives here only while a capability is BUILT but not yet OWED-IN-FULL —
/// the code is good, something the feature promises the user is missing. It is a
/// statement about what this build is allowed to offer, not a configuration
/// surface: nothing here is user-visible or runtime-settable.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether 1:1 A/V calling is reachable in this build. **Off unless
/// `--dart-define=ENABLE_CALLING=true` — which `dart_defines/prod.json` now
/// carries, so every store build since 0.0.6 has calling ON.**
///
/// The gate held while calling owed the user two things. Both are now built:
///
///  1. **The pre-connect disclosure.** Media still terminates at the island's
///     SFU, which decrypts it (forced-relay, no `e2eeOptions`), and the user is
///     TOLD — "not end-to-end encrypted", never "in the clear", because WebRTC
///     mandates DTLS-SRTP. See `features/call/domain/media_confidentiality.dart`.
///  2. **A ring that reaches a closed app.** iOS rings through PushKit/CallKit;
///     Android through an FCM data wake and a full-screen ring (PR #210,
///     design 22). Verified end to end through enspyr 2026-10-09: island sends
///     the wake, a cold locked Pixel rings in 0.40 s, Answer joins.
///
/// Opened on Nick's call, 2026-10-09, for ALL platforms. One gap is accepted,
/// not closed: **macOS has no closed-app ring** — a call reaches the Mac only
/// while the app is open. The gap the flag existed to hide is therefore still
/// real there; it was weighed and shipped, not missed.
///
/// What this flag does NOT cover: cross-island calling carries its own gate
/// (island design 13, Decision 9c / claude-tasks#3697). It is not opened by
/// this flag because callee-hosting is unbuilt — every call is hosted by the
/// island you are signed in to — so a cross-island call cannot be placed. When
/// it is built, #3697 must close first.
///
/// The flag stays (rather than being deleted) so a dev or test build can still
/// run calling OFF, and a bare `flutter build` without prod.json stays
/// calling-less (claude-tasks#4517).
const kCallingEnabled = bool.fromEnvironment('ENABLE_CALLING');

/// [kCallingEnabled] as a provider, so a test can override it and drive BOTH
/// configurations. A bare `const` read at three call sites would make the
/// shipped state the only testable one, and "calling is unreachable" would be a
/// claim no test could ever fail on.
final callingEnabledProvider = Provider<bool>((ref) => kCallingEnabled);
