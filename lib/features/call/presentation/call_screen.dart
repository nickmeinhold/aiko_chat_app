import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../app/providers.dart';
import '../../../app/theme/maritime_theme.dart';
import '../data/call_session.dart';
import '../domain/call_connection_state.dart';

/// Single door for opening a call (#18). Rapid double-taps — or a tap while a
/// call is already open — would otherwise push N [CallScreen]s, each spinning up
/// its own `Room.connect` (N joins for one user, leaked sessions).
/// `context.push` completes only when the call route is POPPED, so the latch is
/// held for the whole call: any launch attempt while one is initiating or live is
/// a no-op. Module-global by design — "is a call being launched" is one app-wide
/// fact, not a per-widget one. (Belt-and-braces with `openDm` idempotency: even a
/// double-fired open resolves to the same room, and this dedups the screen.)
bool _callLaunchInFlight = false;

Future<void> pushCall(BuildContext context, String channelId) =>
    pushCallOn(GoRouter.of(context), channelId);

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
Future<void> pushCallOn(GoRouter router, String channelId) async {
  if (_callLaunchInFlight) return;
  _callLaunchInFlight = true;
  try {
    await router.push('/call/$channelId');
  } finally {
    _callLaunchInFlight = false;
  }
}

/// Clear the launch guard between widget tests (a test that navigates to the
/// call route never pops it, so the latch would leak into the next test). Not a
/// production seam.
@visibleForTesting
void resetCallLaunchGuard() => _callLaunchInFlight = false;

/// Full-screen A/V call for a channel (handoff #2726). Owns a [CallSession] for
/// its lifetime; the room is the channel id. Renders the first remote
/// participant full-screen with a mirrored local PiP overlay.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  late final CallSession _session;

  @override
  void initState() {
    super.initState();
    _session = CallSession(
      api: ref.read(restApiProvider),
      channelId: widget.channelId,
    );
    unawaited(_session.connect());
  }

  @override
  void dispose() {
    // Fire-and-forget: leave() tears down the room + disposes the session's
    // notifiers. The child ValueListenableBuilders unsubscribe first (children
    // unmount before this parent), so disposing the notifiers here is safe.
    unawaited(_session.leave());
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
                // Status / reconnect banner.
                if (state != CallConnectionState.connected)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _statusBanner(state),
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
    final remote = _session.service.remoteParticipants.values;
    final remoteVideo =
        remote.isEmpty ? null : _videoOf(remote.first);
    if (remoteVideo != null) {
      return VideoTrackRenderer(
        remoteVideo,
        fit: VideoViewFit.contain,
      );
    }
    // Connected but no remote video yet → waiting.
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
                child: Icon(Icons.videocam_off, color: Colors.white54))
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
                          strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                Flexible(
                  child: Text(msg,
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _toolbar(CallConnectionState state) {
    final live = state == CallConnectionState.connected ||
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
                background:
                    on ? kMaritimeSignalCyan.withValues(alpha: 0.30) : Colors.white10,
                onTap: () => _session.service.setMicrophoneEnabled(!on),
              ),
            ),
            const SizedBox(width: 24),
            ValueListenableBuilder<bool>(
              valueListenable: _session.service.cameraEnabled,
              builder: (context, on, _) => _circleButton(
                icon: on ? Icons.videocam : Icons.videocam_off,
                background:
                    on ? kMaritimeSignalCyan.withValues(alpha: 0.30) : Colors.white10,
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
                  Text('Receive only',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
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
            onTap: () =>
                context.canPop() ? context.pop() : context.go('/'),
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
            child: Text(text,
                style: const TextStyle(color: Colors.white70),
                textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
