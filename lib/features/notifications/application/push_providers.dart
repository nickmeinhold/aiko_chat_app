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
///
/// IT IS REBUILT BY A GATEWAY SWITCH, which is not obvious from here: it watches
/// [restApiProvider] → `backendProvider` → `configProvider`, and `switchGateway`
/// invalidates that config. Without the dispose below, the outgoing registrar
/// would be dropped while still holding a live `tokenRefreshes` subscription
/// closed over the OLD island's REST client — so a token rotation after the
/// switch would register the new token with the island the user just left.
/// Silent, permanent, and the exact residual the unpair exists to prevent.
final deviceRegistrarProvider = Provider<DeviceRegistrar?>((ref) {
  final source = ref.watch(pushTokenSourceProvider);
  if (source == null) return null;
  final registrar = DeviceRegistrar(
    source: source,
    api: ref.watch(restApiProvider),
  );
  // Cancels the refresh subscription. The unregister inside stop() is a no-op
  // here whenever the caller already unpaired explicitly (`_registered` is
  // null), so this does not double-DELETE on a normal switch.
  ref.onDispose(registrar.stop);
  return registrar;
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
  // WATCH, not read — this pins the registrar to this provider's lifetime, which
  // main() holds for the life of the app.
  //
  // Everything else here only ever `read`s it, and a read neither keeps a
  // provider alive nor guarantees the next read returns the same object. Left
  // unpinned, `start()` could animate one registrar and `stop()` construct a
  // silent twin whose memo has never held a token — so the DELETE never fires
  // and the island's row survives, which is the failure the ordering test was
  // written to prevent. Verifying instance identity in a plain unit test cannot
  // refute this: with no widget scheduler running, the disposal it would catch
  // never fires. The pin is cheap; the proof was not available.
  ref.watch(deviceRegistrarProvider);

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
