import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../data/fcm_token_source.dart';
import '../domain/push_token_source.dart';
import 'device_registrar.dart';

/// Where this platform's push token comes from, or null if we do not take one
/// here.
///
/// NULL IS A REAL ANSWER, not a gap to be filled defensively. A desktop or web
/// build has no push service to ask, and Apple platforms have one that is not
/// wired yet — the native APNs source is the next increment. In every one of
/// those cases the right behaviour is identical: register nothing, and let the
/// app work exactly as it does today. Reaching for the Firebase source as a
/// stopgap on Apple is the specific mistake [FcmTokenSource]'s constructor
/// assertion exists to stop, so this returns null rather than "something".
final pushTokenSourceProvider = Provider<PushTokenSource?>((ref) {
  if (defaultTargetPlatform == TargetPlatform.android) return FcmTokenSource();
  return null;
});

/// The registrar, or null where there is no token source to drive it.
final deviceRegistrarProvider = Provider<DeviceRegistrar?>((ref) {
  final source = ref.watch(pushTokenSourceProvider);
  if (source == null) return null;
  return DeviceRegistrar(source: source, api: ref.watch(restApiProvider));
});

/// Starts the push pairing when a session begins.
///
/// ONLY THE START HALF LIVES HERE, and the asymmetry is deliberate rather than
/// an omission. The two ends of the pairing have different constraints:
///
///   START has no ordering constraint — it needs a live session and nothing
///   more — but it does need COMPLETENESS. There is no single place where the
///   app publishes an authenticated user: sign-in, handle-claim and session
///   restore each land through their own `AsyncValue.guard`. A listener catches
///   all of them, and catches the next one somebody adds without knowing this
///   file exists.
///
///   STOP is the exact opposite. It is ORDERING-CRITICAL — `DELETE /v1/devices`
///   is authenticated, so it must complete before the tokens are cleared — and
///   a listener cannot express that, because it fires after the state has
///   already changed and its async work races the teardown that follows. So
///   stop is an awaited call at the top of `AuthController._teardownResources`,
///   the single door every session-ending path already goes through.
///
/// Watched from `main()` so it is alive before the session restore completes;
/// a listener created later would miss the transition it exists to observe.
final pushPairingProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AppUser?>>(authControllerProvider, (previous, next) {
    final wasSignedIn = previous?.value != null;
    final isSignedIn = next.value != null;
    // Only the EDGE into a session. `refreshUser()` republishes the same user
    // on an ordinary reconcile, and re-running the permission prompt and token
    // fetch on every one of those would be noise the user can see.
    if (!wasSignedIn && isSignedIn) {
      // Unawaited: reach is never a gate on sign-in. The registrar swallows its
      // own failures for the same reason — a device that cannot register is a
      // device that will not be woken, which must not also be a device that
      // cannot sign in.
      ref.read(deviceRegistrarProvider)?.start();
    }
  });
});
