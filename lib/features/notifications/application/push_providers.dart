import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../data/fcm_token_source.dart';
import '../data/pending_unregister_store.dart';
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
  // kIsWeb FIRST, before any platform test (cage-match round 3, Tesla). On
  // Flutter web `defaultTargetPlatform` reports the BROWSER'S HOST OS, not
  // "web" — so Chrome on an Android handset answers `TargetPlatform.android`,
  // and this would construct an `FcmTokenSource` inside a renderer with no FCM
  // plugin behind it. The doc above already promised a web build takes no
  // token; the code did not, and only the prose would ever have told you.
  // LATENT rather than live today — this project has no `web/` target — which
  // is precisely why it would have shipped unnoticed the day somebody adds one.
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.android) return FcmTokenSource();
  return null;
});

/// The device-token debts this app still owes, keyed by island. Durable and
/// deliberately NOT session-scoped — it is written at the moment a session ends.
final pendingUnregisterStoreProvider = Provider<PendingUnregisterStore>(
  (ref) => PendingUnregisterStore(ref.watch(sharedPreferencesProvider)),
);

/// The registrar, or null where there is no token source to drive it.
///
/// IT IS REBUILT BY A GATEWAY SWITCH, which is not obvious from here: it watches
/// [restApiProvider] → `backendProvider` → `configProvider`, and `switchGateway`
/// invalidates that config. Without the dispose below, the outgoing registrar
/// would be dropped while still holding a live `tokenRefreshes` subscription
/// closed over the OLD island's REST client — so a token rotation after the
/// switch would register the new token with the island the user just left.
/// Silent, permanent, and the exact residual the unpair exists to prevent.
///
/// The island's base URL is read from the same `configProvider` that drives the
/// REST client, so a registrar and the debts it records can never disagree about
/// which island they mean.
final deviceRegistrarProvider = Provider<DeviceRegistrar?>((ref) {
  final source = ref.watch(pushTokenSourceProvider);
  if (source == null) return null;
  final registrar = DeviceRegistrar(
    source: source,
    api: ref.watch(restApiProvider),
    pending: ref.watch(pendingUnregisterStoreProvider),
    islandBaseUrl: ref.watch(configProvider).httpBaseUrl,
  );
  // Cancels the refresh subscription and NOTHING else. A rebuild is not a
  // sign-out, so it must not record a debt — see DeviceRegistrar.dispose.
  ref.onDispose(registrar.dispose);
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
///   STOP is the exact opposite. It is ORDERING-CRITICAL relative to the
///   credential clear, and a listener cannot express that, because it fires
///   after the state has already changed and its async work races the teardown
///   that follows. So unpair is called directly from the session-ending paths in
///   `AuthController` — synchronously, and it is a debt record rather than a
///   round trip, so it waits for nothing (see [DeviceRegistrar]).
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
      final registrar = ref.read(deviceRegistrarProvider);
      if (registrar != null) {
        unawaited(() async {
          try {
            // DRAIN BEFORE START, and the sequencing is the entire safety
            // argument for paying an old session's debt under a new session's
            // credential — see DeviceRegistrar's class doc. Reversed, the debt's
            // token has just been re-registered to the current user, so the
            // DELETE would match and destroy the live pairing, not the dead one.
            await registrar.drainPending();
            // RE-CHECK THE SESSION between the two (cage-match round 4, Carnot).
            // The drain is a network round trip, and a logout landing inside it
            // used to let the continuation run anyway — prompting for
            // notification permission on a session that no longer exists, then
            // registering a token for it.
            if (ref.read(authControllerProvider).value == null) return;
            await registrar.start();
          } catch (e) {
            // TERMINAL catch on an unawaited chain. `_register` rethrows
            // `Unauthorized` by design (the auth controller owns that
            // transition), and with nobody awaiting this it would otherwise
            // surface as an unhandled zone error rather than a log line.
            debugPrint('pushPairing: pairing this session failed: $e');
          }
        }());
      }
    }
  });
});
