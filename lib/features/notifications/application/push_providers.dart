import 'dart:async';

import '../../../core/logging/log_providers.dart';
import 'push_telemetry.dart';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/feature_flags.dart' show callingEnabledProvider;
import '../../../app/providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/auth_models.dart';
import '../data/apns_token_source.dart';
import '../data/voip_token_source.dart';
import '../data/fcm_token_source.dart';
import '../data/pending_unregister_store.dart';
import '../domain/push_token_source.dart';
import 'device_registrar.dart';

/// Where this platform's push token comes from, or null if we do not take one
/// here.
///
/// ONE SOURCE PER TRANSPORT, never one SDK for both. Apple platforms hand over
/// the raw APNs device token; Android hands over the FCM registration token.
/// Firebase would relay iOS to APNs for us, and that shortcut is precisely what
/// both constructors assert against — it would put Google in the path on the one
/// platform where Apple is already a mandatory intermediary, invisibly. See
/// [DevicePlatform].
///
/// NULL IS STILL A REAL ANSWER, not a gap to be filled defensively: a desktop or
/// web build has no push service to ask, and the right behaviour there is to
/// register nothing and let the app work exactly as it does today.
///
/// macOS is deliberately null for now. The Dart half above is platform-agnostic,
/// but the native half is not — AppKit registers through `NSApplication`, and a
/// sandboxed macOS app needs its own entitlement in two separate files. Filed
/// rather than assumed-equivalent.
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
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => FcmTokenSource(),
    TargetPlatform.iOS => ApnsTokenSource(
      telemetry: ref.watch(pushTelemetryProvider),
    ),
    _ => null,
  };
});

/// The PushKit VoIP token source — iOS only, and NULL EVERYWHERE ELSE.
///
/// A SECOND source alongside [pushTokenSourceProvider], not a replacement. Both
/// are live at once on an iPhone: one token draws banners, the other rings the
/// handset, and the island stores them as two rows distinguished by
/// `token_kind`.
///
/// **Android's equivalent is not a second token.** FCM issues ONE token and the
/// ring is a high-priority message plus a full-screen intent (design 12
/// Decision 8), so there is deliberately nothing to return there — a second
/// Android source would register the same token twice under two kinds.
///
/// `kIsWeb` first, for the reason [pushTokenSourceProvider] spells out: on web
/// `defaultTargetPlatform` reports the browser's HOST OS, so Safari on an iPhone
/// answers `TargetPlatform.iOS` and this would construct a PushKit source inside
/// a renderer that has never heard of PushKit.
///
/// **GATED ON `callingEnabled`, and the gap it closes was live on this branch.**
/// The flag closes the three visible doors into calling — the `/call/:id` route,
/// the ring banner, the DM long-press action — and said nothing about the VoIP
/// token, which is not a door into calling but a door into being CALLED. So a
/// store build registered a `voip` row, armed PushKit at launch, and would ring
/// full-screen from a locked handset for a call it has no route to answer: rung
/// but unanswerable, in exactly the configuration that ships. The gate's own
/// doc says it closes *every* door; this is one it was not holding.
///
/// **A ROW ALREADY REGISTERED IS NOT REVOKED BY THIS.** A null source means a
/// null registrar, and a null registrar never fires the unregister — so a device
/// that ran an ungated build keeps its island-side `voip` row until something
/// else drains it (claude-tasks#4426, the device-row debt). That set is the
/// handsets this unmerged branch has been on, not the field.
final voipTokenSourceProvider = Provider<PushTokenSource?>((ref) {
  if (kIsWeb) return null;
  if (!ref.watch(callingEnabledProvider)) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => VoipTokenSource(
      telemetry: ref.watch(pushTelemetryProvider),
    ),
    _ => null,
  };
});

/// The push subsystem's telemetry facade.
///
/// Wired to the REAL logger, never [PushTelemetry.noop]. `provider_wiring_test`
/// pins that, because this project has already shipped a telemetry seam that
/// silently fell back to a no-op and swallowed every must-be-seen signal
/// (PR #45, Carnot) — the same defect, in the same shape, one subsystem over.
final pushTelemetryProvider = Provider<PushTelemetry>(
  (ref) => PushTelemetry(ref.watch(rootLoggerProvider).child('push')),
);

/// The device-token debts this app still owes, keyed by island. Durable and
/// deliberately NOT session-scoped — it is written at the moment a session ends.
final pendingUnregisterStoreProvider = Provider<PendingUnregisterStore>(
  (ref) => PendingUnregisterStore(
    ref.watch(sharedPreferencesProvider),
    telemetry: ref.watch(pushTelemetryProvider),
  ),
);

/// The registrar, or null where there is no token source to drive it.
///
/// IT IS REBUILT BY A GATEWAY SWITCH, which is not obvious from here: it watches
/// [restApiProvider] → `backendProvider` → `configProvider`, and `switchIsland`
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
    telemetry: ref.watch(pushTelemetryProvider),
  );
  // Cancels the refresh subscription and NOTHING else. A rebuild is not a
  // sign-out, so it must not record a debt — see DeviceRegistrar.dispose.
  ref.onDispose(registrar.dispose);
  return registrar;
});

/// The registrar for the VoIP token. **A SECOND INSTANCE, not a second mode.**
///
/// [DeviceRegistrar] already threads `source.kind` through every operation it
/// performs — the debt store is keyed on it, the register call carries it, and
/// the drain reads it back. So two kinds is two registrars, and the lifecycle
/// logic that is genuinely hard to get right (drain-before-start, the
/// re-check between them, debt on unpair, disposal on island switch) is reused
/// rather than re-implemented with a kind parameter threaded through it.
///
/// The alternative — one registrar holding two sources — would have to fan every
/// one of those steps out by hand and would make a partial failure across kinds
/// a state nothing models. Two instances make it two independent stories, which
/// is what it actually is: a device can legitimately hold a VoIP token and no
/// alert token, and vice versa.
final voipDeviceRegistrarProvider = Provider<DeviceRegistrar?>((ref) {
  final source = ref.watch(voipTokenSourceProvider);
  if (source == null) return null;
  final registrar = DeviceRegistrar(
    source: source,
    api: ref.watch(restApiProvider),
    pending: ref.watch(pendingUnregisterStoreProvider),
    islandBaseUrl: ref.watch(configProvider).httpBaseUrl,
    telemetry: ref.watch(pushTelemetryProvider),
  );
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
  // PINNED FOR THE SAME REASON, and it is not decoration: read-only access would
  // let `start()` animate one registrar and a later read construct a silent twin
  // whose memo never held a token, so the DELETE on unpair never fires and the
  // island keeps a routable VoIP row. On the alert path that residual is a
  // banner for the previous owner; on THIS path it is a stranger's handset
  // ringing full-screen for them (design 12 Decision 2a, the worst state in the
  // system).
  ref.watch(voipDeviceRegistrarProvider);

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
      // BOTH KINDS, independently. A failure to register one must not prevent
      // the other: "reachable for calls, unreachable for messages" is a normal
      // permanent state (a user who declined notifications), and the mirror is
      // just as real on a build whose PushKit channel is missing.
      //
      // THE TWO CHAINS RUN CONCURRENTLY — each is `unawaited` — and that is safe
      // for a stated reason rather than by luck: `PendingUnregisterStore` is
      // keyed by (island, KIND), so the two drains touch disjoint key sets and
      // cannot race each other's debts. If that keying ever collapses back to
      // island-only, this becomes a real interleaving bug with no test on it.
      for (final registrar in [
        ref.read(deviceRegistrarProvider),
        ref.read(voipDeviceRegistrarProvider),
      ]) {
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
              ref.read(pushTelemetryProvider).pairingFailed(e);
            }
          }());
        }
      }
    }
  });
});
