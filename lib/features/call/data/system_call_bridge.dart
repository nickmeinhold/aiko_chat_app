import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/call_wire.dart' show isCallId;
import '../domain/system_call_action.dart';

/// The two-way seam between the platform's call UI and this app's call
/// (claude-tasks#4420).
///
/// **The ring and the call live on opposite sides of this.** `CallKitRinger` in
/// `ios/Runner/AppDelegate.swift` can make a locked, force-quit handset ring
/// full-screen; it cannot join a room, because the island token, the LiveKit
/// connection and the camera are all Dart's. Everything that turns a ring into a
/// call crosses here.
///
/// Both directions are load-bearing and they fail differently:
///
///  * **[actions] missing** → the user answers and nothing happens. The doorbell
///    on the empty house.
///  * **[end] missing** → a join that fails (or a call the user leaves in-app)
///    leaves the OS showing a CONNECTED call with no media behind it. That
///    phantom outlives the app and the user can only clear it by hanging up a
///    call that was never really there.
abstract class SystemCallBridge {
  /// What the system call UI did. MAY emit before the first frame — a VoIP push
  /// relaunches a terminated app and the user can answer while Dart is still
  /// booting, which is the normal case rather than the edge one.
  Stream<SystemCallAction> get actions;

  /// This channel's system call, if there is one, is over.
  ///
  /// **Safe to call unconditionally**, which is the point: the one Dart teardown
  /// path ([CallScreen.dispose]) fires for outgoing calls and in-app answers
  /// too, and the native side is a structural no-op when the channel names no
  /// system call. Callers do not have to track which kind of call they are in.
  ///
  /// [callId] names WHICH call on the channel: a v2 call by its id, a v1 call
  /// by null. The native side ends only an exact match, so the teardown of
  /// call A can never end call B that displaced it on the same channel
  /// (Carnot + Kelvin, PR #210 v2 round 1).
  Future<void> end(String channelId, {String? callId});
}

/// The native implementation, on BOTH platforms: an `EventChannel` fed by the
/// platform's call UI, and a `MethodChannel` back to it.
///
///  * **iOS** — `SystemCallChannel` in `ios/Runner/AppDelegate.swift`, fed by
///    CallKit.
///  * **Android** — `CallChannels` in `android/app/src/main/kotlin/…`, fed by
///    the FCM ring's notification and lock-screen ring screen
///    (claude-tasks#4421).
///
/// ONE CLASS, NOT TWO, because the two native halves were built to the same
/// channel names, method names and payload keys — pinned on all three sides by
/// `system_call_channel_contract_test.dart`. Two Dart classes would be a place
/// for the platforms to drift that no test watches.
class NativeSystemCallBridge implements SystemCallBridge {
  NativeSystemCallBridge({
    TargetPlatform? platformOverride,
    EventChannel? actions,
    MethodChannel? control,
  }) : assert(
         const {
           TargetPlatform.iOS,
           TargetPlatform.android,
         }.contains(platformOverride ?? defaultTargetPlatform),
         'NativeSystemCallBridge has a native half on iOS and Android only.',
       ),
       _actions = actions ?? const EventChannel(kSystemCallActionsChannel),
       _control = control ?? const MethodChannel(kSystemCallControlChannel);

  final EventChannel _actions;
  final MethodChannel _control;

  @override
  Stream<SystemCallAction> get actions => _actions
      .receiveBroadcastStream()
      .map(_decode)
      .where((a) => a != null)
      .cast<SystemCallAction>();

  /// PERMISSIVE, in the same direction the native half promises to be. An event
  /// whose `action` this build does not know, or which carries no channel, is
  /// dropped — never guessed at. There is no honest default: joining the wrong
  /// room and ending the wrong call are both worse than ignoring the event.
  static SystemCallAction? _decode(dynamic event) {
    if (event is! Map) return null;
    final kind = SystemCallActionKind.parse(event['action'] as String?);
    final channelId = event['channel'];
    if (kind == null || channelId is! String || channelId.isEmpty) return null;
    final origin = event['origin'];
    final call = event['call'];
    // ABSENT means v1. PRESENT-BUT-MALFORMED is not "absent" — read as null it
    // matched every v1 hold and admission in the room, the exact wildcard this
    // id exists to remove (Tesla, PR #210 v2 round 1). It is dropped instead.
    if (call != null && (call is! String || !isCallId(call))) return null;
    return SystemCallAction(
      kind: kind,
      channelId: channelId,
      origin: origin is String && origin.isNotEmpty ? origin : null,
      // Only a canonical id is an id: anything else is treated as absent
      // (v1), never as a key that could match something by accident.
      callId: call as String?,
    );
  }

  @override
  Future<void> end(String channelId, {String? callId}) async {
    try {
      await _control.invokeMethod<void>('endSystemCall', {
        'channel': channelId,
        if (callId != null) 'call': callId,
      });
    } on MissingPluginException {
      // An older native half, or a platform that never registered the channel.
      // Swallowed deliberately: this is called from a teardown path, and a
      // failure to clear a system call must never take out the leave that is
      // clearing the room.
    } on PlatformException {
      // Same argument. The native side answers an error only when it was asked
      // to end nothing at all, which is a bug on this side and not a state the
      // user can act on.
    }
  }
}

/// The event channel the native half emits system-call transitions on.
///
/// Named constants because `apns_channel_contract_test.dart` exists: a channel
/// name that drifts from its Swift twin fails by the app simply never being
/// told the user answered, which is the silent shape this whole feature is
/// built against.
const kSystemCallActionsChannel = 'cc.imagineering.aikoChatApp/call/actions';

/// The method channel Dart ends a system call on.
const kSystemCallControlChannel = 'cc.imagineering.aikoChatApp/call/control';

/// How long an admitted invitation remains proof that this handset could still
/// be ringing for that channel.
///
/// **THE SAME NUMBER AS `CallKitRinger.liveCallTrustWindow`, and that is the
/// whole point.** The native side stops believing in an unanswered ring past
/// this bound; an app-side proof that outlived it would be vouching for a call
/// the device itself has forgotten, and one that died sooner would hang up on a
/// handset that is still ringing. Two halves of one quantity, in two languages
/// — so it is pinned across the boundary by
/// `system_call_channel_contract_test.dart` rather than by this comment.
const Duration kSystemCallRingTrust = Duration(seconds: 120);
