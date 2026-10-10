import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../app/providers.dart';
import '../../../core/logging/log_providers.dart';
import '../../../app/theme/maritime_theme.dart';
import '../application/call_end_announcer.dart';
import '../application/system_call_providers.dart';
import '../application/ring_telemetry.dart';
import '../data/call_session.dart';
import '../data/system_call_bridge.dart';
import '../domain/call_connection_state.dart';
import '../domain/call_wire.dart' show CallRef;
import 'media_confidentiality_chip.dart';

/// Single door for opening a call (#18). Rapid double-taps — or a tap while a
/// call is already open — would otherwise push N [CallScreen]s, each spinning up
/// its own `Room.connect` (N joins for one user, leaked sessions).
/// `context.push` completes only when the call route is POPPED, so the latch is
/// held for the whole call: any launch attempt while one is initiating or live is
/// a no-op. Module-global by design — "is a call being launched" is one app-wide
/// fact, not a per-widget one. (Belt-and-braces with `openDm` idempotency: even a
/// double-fired open resolves to the same room, and this dedups the screen.)
bool _callLaunchInFlight = false;

/// Set when the mounted call route has reached [CallConnectionState.ended].
///
/// "A call route is open" and "a call is live" STOP BEING THE SAME FACT the
/// moment an ended call screen stays mounted waiting to be closed — which is
/// exactly what this feature now does, deliberately, rather than vanishing
/// under the reader. Without this split the ring banner would refuse a genuine
/// new call with "You're already in a call" for a call that is over.
bool _mountedCallEnded = false;

/// Whether a call route is currently open — live OR ended-but-not-yet-closed.
bool get isCallRouteOpen => _callLaunchInFlight;

/// Whether the user is in a LIVE call.
///
/// Exposed because [pushCallOn] silently returns while a route is open, and the
/// ring banner's Answer is the one caller for whom that silence is
/// user-visible: it stops the ring first, then no-ops, so the banner vanishes
/// and no call opens. A caller that can be refused has to be able to ask — and
/// has to be told the truth about which of the two conditions refused it.
bool get isInLiveCall => _callLaunchInFlight && !_mountedCallEnded;

/// What a `/call/:channelId` navigation carries beyond the room: WHICH call,
/// and whether this device placed it (only the caller announces the hangup).
///
/// Required, never null: a joined room is a call, and a call has a [CallRef]
/// (design 22 v2.5). A navigation without one — a bare deep link — is
/// redirected home by the router and joins nothing.
typedef CallRouteExtra = ({CallRef call, bool outgoing});

Future<void> pushCall(
  BuildContext context,
  String channelId, {
  required CallRef call,
  bool outgoing = false,
}) =>
    pushCallOn(GoRouter.of(context), channelId, call: call, outgoing: outgoing);

/// Router-first form of [pushCall], for callers that have a [GoRouter] but no
/// in-scope context.
///
/// The ring banner is one: it is mounted in `MaterialApp.router`'s `builder`,
/// which wraps the Router's output from ABOVE — so its context sits OUTSIDE
/// `InheritedGoRouter` and `context.push` throws `No GoRouter found in context`.
/// That killed the feature's primary button while 701 tests stayed green,
/// because every test stopped one layer below the tap (cage-match #139,
/// Maxwell; pinned by `ring_overlay_test.dart`). The banner reaches the router
/// through `routerProvider` instead. Both entry points share the ONE latch, so
/// "is a call being launched" stays a single app-wide fact.
Future<void> pushCallOn(
  GoRouter router,
  String channelId, {
  required CallRef call,
  bool outgoing = false,
}) async {
  if (_callLaunchInFlight) return;
  _callLaunchInFlight = true;
  try {
    final CallRouteExtra extra = (call: call, outgoing: outgoing);
    await router.push('/call/$channelId', extra: extra);
  } finally {
    _callLaunchInFlight = false;
  }
}

/// Clear the launch guard between widget tests (a test that navigates to the
/// call route never pops it, so the latch would leak into the next test). Not a
/// production seam.
/// [pushCallOn] for an answer that arrives while a SPENT call route — "Call
/// ended", not yet closed — still holds the latch: close it first, then push.
///
/// Without this a system-UI answer during that window was consumed, recorded
/// as joined, and then silently dropped by the latch, with the OS showing a
/// connected call and no room behind it (Tesla, PR #210 v2 round 2). The ring
/// banner's Answer already did this inline; this is the one door for both.
/// A LIVE call is the caller's to refuse — this never closes one.
Future<void> pushCallOverSpent(
  GoRouter router,
  String channelId, {
  required CallRef call,
}) async {
  if (isCallRouteOpen && !isInLiveCall) {
    if (router.canPop()) router.pop();
    // The latch is released when the popped route's `router.push` future
    // resolves, which is after this turn.
    await Future<void>.delayed(Duration.zero);
  }
  await pushCallOn(router, channelId, call: call);
}

@visibleForTesting
void resetCallLaunchGuard() {
  _callLaunchInFlight = false;
  _mountedCallEnded = false;
}

/// Mark the mounted call route's call as over, for a test whose call route is
/// a stand-in with no [CallSession]. Not a production seam.
@visibleForTesting
void debugMarkMountedCallEnded() => _mountedCallEnded = true;

/// The `/call/:channelId` route's redirect: a navigation that names no call
/// (a bare or crafted deep link) goes home and joins nothing. A joined room
/// that no event can address was the "hot mic with no name" (Tesla, design 22
/// temper round 1).
String? callRouteRedirect(Object? extra) =>
    extra is CallRouteExtra ? null : '/';

/// Full-screen A/V call for a channel. Owns a [CallSession] for
/// its lifetime; the room is whatever the island's minted token names (it is
/// derived from the channel, but is NOT the bare channel id). Renders the first remote
/// participant full-screen with a mirrored local PiP overlay.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({
    super.key,
    required this.channelId,
    required this.call,
    this.outgoing = false,
  });

  final String channelId;

  /// The call this screen is in. Its teardown ends exactly this call.
  final CallRef call;

  /// Whether this device placed the call. Only the caller announces the end:
  /// an end from anyone else would be refused at the peer ([admitCallEnd]),
  /// so sending one would be a signed row saying nothing.
  final bool outgoing;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallSession _session;

  /// The announcer, captured in [initState] because [dispose] must not touch
  /// `ref`. Capturing THIS is safe where capturing a repository was not: it is
  /// app-scoped, so it outlives both this screen and any number of repository
  /// rebuilds, and it resolves the live repository itself at send time.
  late final CallEndAnnouncer _endAnnouncer;

  /// The system call UI, when this platform has one. See [dispose].
  SystemCallBridge? _systemCall;
  late final RingTelemetry _telemetry;

  @override
  void initState() {
    super.initState();
    _session = CallSession(
      api: ref.read(restApiProvider),
      channelId: widget.channelId,
      // The media layer swallowed every publish failure until 2026-09-16 — a
      // call could carry video, silently fail to carry audio, and leave no
      // trace. This is the wire that makes the failure reportable.
      log: ref.read(rootLoggerProvider).child('call'),
    );
    _endAnnouncer = ref.read(callEndAnnouncerProvider);
    // Captured here for the same reason as the announcer: `dispose` must not
    // touch `ref`. Null on every platform without a system call UI, and null in
    // a build with calling gated off — both of which make the teardown below a
    // no-op rather than a special case.
    _systemCall = ref.read(systemCallBridgeProvider);
    // Captured for the same reason as the bridge: `dispose` must not touch
    // `ref`, and the disposal is exactly the event worth recording.
    _telemetry = ref.read(ringTelemetryProvider);
    _telemetry.callScreenOpened(widget.channelId);
    // This route owns the module-level liveness flag for its whole lifetime:
    // cleared on mount, set when the call ends, cleared again on dispose so a
    // later call never inherits a stale `ended`.
    _mountedCallEnded = false;
    _session.state.addListener(_trackLiveness);
    // THIS CALL IS LIVE, as far as the native half is concerned: it refuses a
    // second system answer from here until `end` (design 22 v4.2). Outgoing
    // and answered calls alike, because the native half otherwise knew only
    // the calls IT answered, and only for 120s (design 22 temper round 3).
    unawaited(
      _systemCall?.callStarted(widget.channelId, widget.call) ??
          Future<void>.value(),
    );
    unawaited(_session.connect());
  }

  void _trackLiveness() {
    final ended = _session.state.value == CallConnectionState.ended;
    if (ended && !_mountedCallEnded) {
      // THE CALL IS OVER NOW, not when this screen is closed. The native half
      // refuses a second system answer while a call is live (design 22 v4.2),
      // and a "Call ended" screen can stay up indefinitely — so ending the
      // system call only at dispose left native refusing an answer that Dart's
      // own door (`pushCallOverSpent`) would allow. Dispose ends it again;
      // ending is idempotent. (Fix-interaction pass, design 22 build.)
      unawaited(
        _systemCall?.end(widget.channelId, widget.call) ?? Future<void>.value(),
      );
    }
    _mountedCallEnded = ended;
  }

  @override
  void dispose() {
    _telemetry.callScreenDisposed(widget.channelId);
    _session.state.removeListener(_trackLiveness);
    _mountedCallEnded = false;
    // Fire-and-forget: leave() tears down the room + disposes the session's
    // notifiers. The child ValueListenableBuilders unsubscribe first (children
    // unmount before this parent), so disposing the notifiers here is safe.
    unawaited(_session.leave());
    // HAND OVER THE OBLIGATION; do not try to discharge it here. Every exit
    // lands in dispose — the leave button, a system back, a pop from anywhere —
    // which is why the announcement belongs here and the ANNOUNCING does not.
    // The screen is the wrong owner for work that may have to outlive it: the
    // invitation may not be acked yet (so it has no id the wire can name) and
    // this widget's repository may be replaced mid-ring. See CallEndAnnouncer.
    if (widget.outgoing) {
      _endAnnouncer.announce(channelId: widget.channelId, call: widget.call);
    }
    // TELL THE OS THE CALL IS OVER — unconditionally, from the one place every
    // exit already lands in.
    //
    // Unconditional is what makes it correct rather than what makes it lazy:
    // the native side ends a system call for this channel only if one exists,
    // so an outgoing call, an in-app answer, or a call on a platform with no
    // CallKit all resolve to nothing happening. The alternative — tracking here
    // whether THIS call came from a ring — is a second copy of a fact the
    // native side already holds, and the failure of getting it wrong is a
    // phantom connected call in the system UI that outlives the app.
    unawaited(
      _systemCall?.end(widget.channelId, widget.call) ?? Future<void>.value(),
    );
    super.dispose();
  }

  /// The first available (unmuted) video track on [p], or null.
  VideoTrack? _videoOf(Participant? p) {
    if (p == null) return null;
    for (final pub in p.videoTrackPublications) {
      final track = pub.track;
      if (track is VideoTrack && !pub.muted) return track;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Always maritime-dark (an immersive video surface stays dark regardless of
      // the app's light/dark mode), but the brand sea-night, not generic black.
      backgroundColor: kMaritimeSeaNight,
      body: SafeArea(
        child: ValueListenableBuilder<CallConnectionState>(
          valueListenable: _session.state,
          builder: (context, state, _) {
            return Stack(
              children: [
                // Video area rebuilds on any track/participant change.
                Positioned.fill(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _session.service.tracksRevision,
                    builder: (context, _, _) => _videoArea(state),
                  ),
                ),
                // Status / reconnect banner, and the disclosure under it.
                //
                // The chip is OUTSIDE the state check on purpose: it is drawn
                // in every state including `connecting`, which is this screen's
                // first frame and therefore before any media flows. Decision 9d
                // says the user is told BEFORE connect, and an indicator that
                // waited for `connected` would arrive after the thing it warns
                // about.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (state != CallConnectionState.connected)
                        _statusBanner(state),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 10, 12, 0),
                        child: MediaConfidentialityChip(),
                      ),
                    ],
                  ),
                ),
                // Local camera PiP (only once we're in the room, and only if we
                // can publish — a subscribe-only member has no local camera).
                if ((state == CallConnectionState.connected ||
                        state == CallConnectionState.reconnecting) &&
                    _session.service.canPublish)
                  Positioned(
                    right: 16,
                    bottom: 96,
                    width: 110,
                    height: 160,
                    child: _localPip(),
                  ),
                // Toolbar.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _toolbar(state),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _videoArea(CallConnectionState state) {
    if (state == CallConnectionState.videoUnavailable) {
      return _centeredMessage(
        Icons.videocam_off,
        "Video calling isn't available here yet",
      );
    }
    if (state == CallConnectionState.failed) {
      return _centeredMessage(
        Icons.error_outline,
        _session.message.value ?? 'Call connection failed',
      );
    }
    if (state == CallConnectionState.ended) {
      return _centeredMessage(Icons.call_end, 'Call ended');
    }
    final remote = _session.service.remoteParticipants.values;
    final peer = remote.isEmpty ? null : remote.first;
    final remoteVideo = _videoOf(peer);
    if (remoteVideo != null) {
      return VideoTrackRenderer(remoteVideo, fit: VideoViewFit.contain);
    }
    if (peer != null) {
      // THEY ARE HERE, with their camera off. `_videoOf` returns null both for
      // "no participant" and for "participant with no unmuted video", so these
      // two used to render identically — telling you someone who is talking to
      // you has not arrived. It also covers the mid-call camera toggle:
      // TrackMuted bumps, and this screen used to announce their departure.
      //
      // No name in the copy: participant identity is baked into the JWT the
      // island minted, and `VideoToken` carries only token/url/room, so the app
      // cannot name them — and a wrong name is worse than none.
      return _centeredMessage(Icons.videocam_off, 'Their camera is off');
    }
    return _centeredMessage(
      Icons.hourglass_empty,
      state == CallConnectionState.connecting
          ? 'Connecting…'
          : 'Waiting for the other person to join…',
    );
  }

  Widget _localPip() {
    final localVideo = _videoOf(_session.service.localParticipant);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: Colors.white12,
        child: localVideo == null
            ? const Center(
                child: Icon(Icons.videocam_off, color: Colors.white54),
              )
            : VideoTrackRenderer(
                localVideo,
                fit: VideoViewFit.cover,
                mirrorMode: VideoViewMirrorMode.mirror,
              ),
      ),
    );
  }

  Widget _statusBanner(CallConnectionState state) {
    return ValueListenableBuilder<String?>(
      valueListenable: _session.message,
      builder: (context, msg, _) {
        if (msg == null) return const SizedBox.shrink();
        return Material(
          color: Colors.black54,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (state == CallConnectionState.reconnecting ||
                    state == CallConnectionState.connecting)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                Flexible(
                  child: Text(
                    msg,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(CallConnectionState state) {
    if (state == CallConnectionState.ended) {
      // The red hang-up circle is a lie twice over here: there is nothing left
      // to end, and red reads as danger for what is simply the call being over.
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        color: Colors.black38,
        child: Center(
          child: FilledButton.icon(
            // Same canPop fallback the leave button carries: a deep-linked
            // /call/:id has an empty stack.
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
            icon: const Icon(Icons.close),
            label: const Text('Close'),
          ),
        ),
      );
    }
    final live =
        state == CallConnectionState.connected ||
        state == CallConnectionState.reconnecting;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      color: Colors.black38,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (live && _session.service.canPublish) ...[
            ValueListenableBuilder<bool>(
              valueListenable: _session.service.micEnabled,
              builder: (context, on, _) => _circleButton(
                icon: on ? Icons.mic : Icons.mic_off,
                background: on
                    ? kMaritimeSignalCyan.withValues(alpha: 0.30)
                    : Colors.white10,
                onTap: () => _session.service.setMicrophoneEnabled(!on),
              ),
            ),
            const SizedBox(width: 24),
            ValueListenableBuilder<bool>(
              valueListenable: _session.service.cameraEnabled,
              builder: (context, on, _) => _circleButton(
                icon: on ? Icons.videocam : Icons.videocam_off,
                background: on
                    ? kMaritimeSignalCyan.withValues(alpha: 0.30)
                    : Colors.white10,
                onTap: () => _session.service.setCameraEnabled(!on),
              ),
            ),
            const SizedBox(width: 24),
          ] else if (live) ...[
            // Subscribe-only (can_publish:false) — no camera/mic to toggle.
            const Padding(
              padding: EdgeInsets.only(right: 24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility, size: 18, color: Colors.white70),
                  SizedBox(width: 8),
                  Text(
                    'Receive only',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
          _circleButton(
            icon: Icons.call_end,
            background: Colors.red,
            // Fall back to '/' when there's nothing to pop — a cold/deep-linked
            // /call/:id has an empty stack, so a bare pop() would be a dead
            // button and leave() would never run (cage-match Carnot+Tesla HIGH).
            onTap: () => context.canPop() ? context.pop() : context.go('/'),
          ),
        ],
      ),
    );
  }

  Widget _circleButton({
    required IconData icon,
    required Color background,
    required VoidCallback onTap,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }

  Widget _centeredMessage(IconData icon, String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white54, size: 48),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
