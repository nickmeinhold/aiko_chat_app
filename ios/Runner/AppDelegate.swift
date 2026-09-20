import Flutter
import UIKit
import os
import AVFoundation
import CallKit
import PushKit
import UserNotifications
import WebRTC

/// The CallKit ↔ WebRTC audio handoff, and the reason a CallKit-answered call
/// was silent until 2026-09-16.
///
/// **NOBODY OWNED THE AUDIO SESSION.** CallKit activates the `AVAudioSession`
/// itself when a call is answered and announces it via
/// `provider(_:didActivate:)`; WebRTC, left alone, activates its own on its own
/// clock (`AudioUtils.ensureAudioSessionWithRecording:`). Neither knew about the
/// other, so the first complete call this product ever made — rang, answered,
/// connected — carried no sound.
///
/// Neither Dart package exposes the fix: `flutter_webrtc 1.6.0` has no
/// `useManualAudio`/`audioSessionDidActivate` surface at all (checked in Dart
/// AND `common/darwin/Classes`), and `livekit_client 2.8.1` configures only the
/// category. But `WebRTC` is an **exported SPM library product** of the
/// flutter_webrtc package — its `Package.swift` exports it precisely "so
/// dependent plugins can import WebRTC without declaring a second copy of the
/// binary target" — so `RTCAudioSession` is reachable from here directly. The
/// package's API surface and the platform's are different questions.
///
/// ## ARMED PER CALL, NEVER GLOBALLY — this is the whole design
///
/// `useManualAudio` is a process-wide switch, and the textbook recipe sets it
/// once at launch. **That would break a path that works today.** This app has
/// TWO ways to answer: CallKit, and `ring_overlay.dart`'s in-app `_RingBanner`,
/// which pushes `/call/...` with CallKit nowhere in it. In manual mode WebRTC
/// waits for an `audioSessionDidActivate` that only CallKit ever sends — so a
/// global switch silences the in-app path, which currently carries sound, while
/// demoing perfectly on the CallKit test that motivated the change.
///
/// So manual mode is ENTERED on a CallKit answer and LEFT on that call's end.
/// The in-app path never sees it and keeps WebRTC's automatic management.
///
/// **Every exit must disarm, including the abnormal ones.** Leaving the process
/// in manual mode with audio disabled is a silent, durable break of the in-app
/// path that outlives the call that caused it — worse than the bug being fixed,
/// because it needs no CallKit call to reproduce and nothing reports it.
enum CallAudioSession {
  /// The process-wide WebRTC configuration as it was BEFORE the first `arm()`.
  ///
  /// `setWebRTC` is a GLOBAL mutation — it changes what WebRTC re-applies every
  /// time it later takes the session, for the life of the process — and nothing
  /// used to put it back. So the doc above ("the in-app path never sees it") was
  /// true of manual mode and false of the configuration: after one CallKit
  /// answer, every in-app call inherited playAndRecord/videoChat/allowBluetooth
  /// whether or not CallKit was involved. Audio routing that differs before and
  /// after the first CallKit call, within one launch, is the most expensive bug
  /// shape there is — two identical runs behaving differently.
  ///
  /// Captured on the FIRST arm only. A later arm would capture the config the
  /// previous arm installed, which restores nothing.
  ///
  /// **FIELDS, NOT THE OBJECT, AND THAT IS DELIBERATE.** `webRTCConfiguration` is
  /// declared `+ (instancetype)` and the header does not say whether it hands back
  /// a copy or the shared global; the implementation is not in the binary
  /// framework, so it cannot be verified from this checkout. Holding the returned
  /// OBJECT would make this restore correct under one reading and a silent no-op
  /// under the other — we would be mutating the very instance we saved. Copying
  /// the three values we overwrite is correct under both, and costs three lines.
  /// (Carnot + Maxwell, cage-match PR #201 round 1; semantics unverifiable, so
  /// the dependency is removed rather than assumed.)
  private static var configBeforeArm: (category: String, mode: String, options: AVAudioSession.CategoryOptions)?

  /// Hand WebRTC over to CallKit for this call. Called from the answer action
  /// BEFORE Dart is told to join, so manual mode is in force before any audio
  /// track can start — if a track started first it would already have taken the
  /// session under automatic management.
  /// Returns whether the session is actually usable. **A `false` here means the
  /// answer cannot carry media**, and the caller must not present it as connected
  /// — see the answer handler.
  @discardableResult
  static func arm() -> Bool {
    let session = RTCAudioSession.sharedInstance()
    session.useManualAudio = true
    // Audio stays OFF until CallKit hands us an activated session. This is the
    // half that makes the handoff a handoff rather than a race.
    session.isAudioEnabled = false

    // THE HALF THAT WAS MISSING, and it is why no call has ever carried sound.
    //
    // MEASURED 2026-09-20, from the device log, on the first call that ever
    // connected:
    //
    //     13:19:17.692  [audio] arm — manual audio ON, audio DISABLED …
    //     13:19:17.692  [callkit] CXAnswerCallAction fulfilled for channel …
    //     (no didActivate, ever)
    //
    // and in the same call, from the app's own report:
    //
    //     microphone.publish.failed reason=AudioProcessingException cause=applyFailed
    //
    // `applyFailed` is `adm.initAndStartRecording()` returning non-zero
    // (`LiveKitPlugin.handleStartLocalRecording`). With `isAudioEnabled` still
    // false there is nothing for the recorder to start — and it stays false
    // because `didActivate` never arrives.
    //
    // CallKit activates the app's audio session after the answer action is
    // fulfilled, but only once there IS a session configured to activate.
    // `arm()` declared the handoff and never described the session, so there
    // was nothing on the other end of it. Configuring here, BEFORE `fulfill()`
    // (`arm` is called from the answer handler ahead of both the Dart emit and
    // the fulfill), is the documented order.
    //
    // `RTCAudioSessionConfiguration.setWebRTC` as well as `setConfiguration`:
    // the first is what WebRTC re-applies whenever it later takes the session,
    // so setting only the live session would be undone the moment the ADM
    // reconfigured. Both, or the fix has a lifetime of one route change.
    // Capture BEFORE mutating, once, so `disarm()` has something to restore.
    if configBeforeArm == nil {
      let prior = RTCAudioSessionConfiguration.webRTC()
      configBeforeArm = (prior.category, prior.mode, prior.categoryOptions)
    }
    let config = RTCAudioSessionConfiguration.webRTC()
    config.category = AVAudioSession.Category.playAndRecord.rawValue
    // `.videoChat`, not `.voiceChat`: every call this app places is a video
    // call (`update.hasVideo = true`), and videoChat defaults the route to the
    // speaker, which is the only sensible output for a phone you are looking
    // at. voiceChat would route to the earpiece and be indistinguishable, from
    // the user's side, from the silence we are fixing.
    config.mode = AVAudioSession.Mode.videoChat.rawValue
    config.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    RTCAudioSessionConfiguration.setWebRTC(config)

    var configured = false
    session.lockForConfiguration()
    do {
      try session.setConfiguration(config)
      configured = true
      os_log(
        "[audio] arm — manual audio ON, session configured (playAndRecord/videoChat), audio DISABLED until didActivate",
        log: aikoCallLog, type: .info)
    } catch {
      // LOUD, and `.error` so it survives a level filter. A configuration that
      // fails here produces exactly the symptom this comment describes — a
      // ringing, answered, silent call — and the whole point of the day is
      // that such a failure must never again be inferred from an absence.
      os_log(
        "[audio] arm — setConfiguration FAILED: %{public}@", log: aikoCallLog,
        type: .error, error.localizedDescription)
    }
    session.unlockForConfiguration()
    return configured
  }

  /// CallKit activated the session — release WebRTC onto it.
  static func didActivate(_ audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidActivate(audioSession)
    session.isAudioEnabled = true
    os_log("[audio] didActivate — audio ENABLED, WebRTC released onto the session", log: aikoCallLog, type: .info)
  }

  /// CallKit tore the session down.
  static func didDeactivate(_ audioSession: AVAudioSession) {
    let session = RTCAudioSession.sharedInstance()
    session.audioSessionDidDeactivate(audioSession)
    session.isAudioEnabled = false
    os_log("[audio] didDeactivate — audio disabled", log: aikoCallLog, type: .info)
  }

  /// Return the process to automatic management. Idempotent, and safe to call
  /// on a path that never armed — which is why it is called from EVERY end,
  /// rather than only from the ones believed to follow an answer.
  static func disarm() {
    let session = RTCAudioSession.sharedInstance()
    session.isAudioEnabled = false
    session.useManualAudio = false
    // THE GLOBAL HALF. Restoring `useManualAudio` alone left the process-wide
    // WebRTC configuration permanently as CallKit shaped it, which is the half
    // of "back to automatic management" that was never implemented.
    if let previous = configBeforeArm {
      let restored = RTCAudioSessionConfiguration.webRTC()
      restored.category = previous.category
      restored.mode = previous.mode
      restored.categoryOptions = previous.options
      RTCAudioSessionConfiguration.setWebRTC(restored)
      configBeforeArm = nil
    }
    os_log("[audio] disarm — back to automatic management, WebRTC config restored", log: aikoCallLog, type: .info)
  }
}

/// The app's own marker log, readable from a device log archive.
///
/// NOT `NSLog`. The unified log redacts an NSLog message BODY by default, so
/// every marker this file writes came back as `(Foundation) <private>` — present,
/// timestamped, and unreadable, which is the purest form of the failure this
/// whole subsystem spent 2026-09-20 removing. A named subsystem plus static
/// format strings is public by construction, and makes one predicate
/// (`subsystem == "cc.imagineering.aikoChatApp"`) pull every marker out.
///
/// Any INTERPOLATED value needs `%{public}@` explicitly — the default for
/// arguments is still private. Only opaque ids go through here (a channel ULID,
/// a call UUID); nothing user-authored, by the same rule `RingTelemetry` keeps
/// on the Dart side.
let aikoCallLog = OSLog(subsystem: "cc.imagineering.aikoChatApp", category: "call")

/// The APNs device token, taken from Apple DIRECTLY.
///
/// Not via FlutterFire, and the reason is not purity. On iOS Apple is already a
/// mandatory intermediary — there is no third-party push on the platform, and a
/// suspended app can only be woken through APNs. Relaying iOS pushes through
/// Firebase would add Google as a SECOND intermediary on the one platform where
/// we had no choice about the first, and buy nothing but a smaller diff. On a
/// product whose thesis is sovereignty that is the wrong trade, and it is
/// invisible once made. `DevicePlatform` carries the same argument on the Dart
/// side, and `FcmTokenSource`'s constructor asserts against being used here.
///
/// This lives in AppDelegate.swift rather than its own file ON PURPOSE: a new
/// `.swift` that nobody adds to the Runner target compiles to nothing, links to
/// nothing, and fails by the app simply never receiving a token — the same
/// silent-failure shape the whole feature is trying to avoid. The delegate
/// callbacks it needs are here anyway.
final class ApnsTokenChannel: NSObject, FlutterStreamHandler {
  static let shared = ApnsTokenChannel()

  private var sink: FlutterEventSink?

  /// The last token handed to Dart, so a re-registration reporting the SAME
  /// value is not published as a rotation. iOS calls the delegate on every
  /// `registerForRemoteNotifications()`, including ordinary app launches.
  private var lastReported: String?

  /// Callers of `currentToken` waiting on the first delegate callback. A list,
  /// not a single slot: `start()` is fire-and-forget, so two sign-in edges can
  /// overlap, and a single slot would drop one caller's continuation forever —
  /// leaving a Dart future that never completes and a device never registered.
  private var waiters: [(String?) -> Void] = []

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(
      name: "cc.imagineering.aikoChatApp/apns",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "requestPermission": self.requestPermission(result)
      case "currentToken": self.currentToken(result)
      case "apnsEnvironment": result(ApnsTokenChannel.apnsEnvironment())
      default: result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(
      name: "cc.imagineering.aikoChatApp/apns/refreshes",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(self)
  }

  /// Which APNs host will accept the tokens this build mints — `development`
  /// (sandbox) or `production`.
  ///
  /// READ FROM THE PROVISIONING PROFILE STAPLED TO THIS BINARY, not from
  /// `Runner.entitlements`. That file statically says `development` and Xcode
  /// REWRITES the key at export time from the signing profile, so the checked-in
  /// value is the debug answer on every distribution build — "just read the
  /// entitlements file" returns a confident wrong answer and nothing fails.
  ///
  /// The profile cannot drift the same way: it is embedded by the signing step
  /// that decides the environment, in the same operation. A `--dart-define`
  /// would have been a MIRROR of a fact settled after the Dart code is compiled;
  /// this is the fact itself.
  ///
  /// Falls back to the build configuration when no profile is readable. That
  /// direction is deliberate: an unreadable profile on a Release build means a
  /// distribution artifact, and the failure of guessing `development` there is
  /// the silent one we are removing (island resolves an omitted value to its
  /// `APNS_USE_SANDBOX`, `true` on both boxes).
  static func apnsEnvironment() -> String {
    if let declared = apsEnvironmentFromProvisioningProfile() { return declared }
    #if DEBUG
      return "development"
    #else
      return "production"
    #endif
  }

  /// `Entitlements.aps-environment` out of `embedded.mobileprovision`.
  ///
  /// The file is CMS-signed DER with the plist as a payload, so there is no
  /// plist parser that will open it directly — the XML has to be sliced out of
  /// the surrounding binary first. `</plist>` is matched BACKWARDS because the
  /// signature blob trails the payload and can itself contain the bytes of a
  /// shorter match.
  private static func apsEnvironmentFromProvisioningProfile() -> String? {
    guard
      let url = Bundle.main.url(
        forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), options: [.backwards])
    else { return nil }
    let plist = try? PropertyListSerialization.propertyList(
      from: data.subdata(in: start.lowerBound..<end.upperBound),
      options: [], format: nil)
    guard
      let root = plist as? [String: Any],
      let entitlements = root["Entitlements"] as? [String: Any]
    else { return nil }
    return entitlements["aps-environment"] as? String
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, _ in
      // A denial is an ordinary answer, not an error — the user has said they do
      // not want to be woken and the app must keep working exactly as it does
      // today. An authorization ERROR is reported the same way for the same
      // reason: there is nothing to retry and nothing to tell them.
      DispatchQueue.main.async { result(granted) }
    }
  }

  private func currentToken(_ result: @escaping FlutterResult) {
    if let token = lastReported { return result(token) }
    waiters.append { result($0) }
    // MUST be on the main thread, and must be called even when a token was
    // already issued this install: registration is what makes iOS deliver the
    // delegate callback we are waiting on.
    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
  }

  /// Called by the delegate on success. Resolves anyone waiting for a first
  /// token, and publishes a genuine ROTATION to the stream.
  func received(token: String) {
    let isRotation = lastReported != nil && lastReported != token
    lastReported = token
    drainWaiters(with: token)
    // Tokens rotate on reinstall and restore-from-backup. A registrar that only
    // ever read the first one silently stops being reachable the first time that
    // happens, and nothing fails — the island simply holds a token APNs refuses
    // to deliver to.
    if isRotation { sink?(token) }
  }

  /// Called by the delegate on failure. Resolving the waiters with nil rather
  /// than leaving them hanging is the point: an unreachable APNs is a device
  /// that will not be woken, which must never also be a device that cannot
  /// finish signing in.
  func failed() { drainWaiters(with: nil) }

  private func drainWaiters(with token: String?) {
    let pending = waiters
    waiters = []
    pending.forEach { $0(token) }
  }

  func onListen(
    withArguments _: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// The channel id from a TAPPED call notification, handed to Dart so the app can
/// open the conversation the call is in (claude-tasks#3588).
///
/// Until this existed the push landed, the handset lit up, and tapping it opened
/// the app on whatever screen it was last on — indistinguishable to the user
/// from the app having ignored the call. That is the same silent-failure shape
/// `ApnsTokenChannel` above was written against, one layer further in.
///
/// **THE PAYLOAD KEY IS `c`, ONE CHARACTER.** The island sends exactly
/// `{"aps": {...}, "c": "<channel_id>"}` and nothing else — the short name is
/// deliberate there (a 4KB APNs ceiling, and `c` is its only custom field).
/// Reading `channel_id` or `channelId` here yields nil, routes nowhere, and
/// reports no problem, which is precisely how this bug family hides.
///
/// **IT IS A CHANNEL ID, NEVER A CALL ID.** So this opens the CONVERSATION and
/// lets the existing ring machinery decide whether there is a live call to
/// answer. That is deliberate and it is the whole safety argument: `admitRing`
/// carries TWELVE start-gate refusals and a tap handler that navigated straight
/// into a call screen would be a second admission path honouring none of them.
///
/// **TWELVE, AND `grep -c "startGate: true"` ANSWERS NINE.** `startGate`
/// DEFAULTS to true, so the three that declare only `refusedAnAttempt` are
/// invisible to the obvious grep — and they include `unverifiedOrigin`, the
/// signature check, which is the one gate this product's whole thesis rests on.
/// The enum is the census (`call_invite_test.dart` asserts set equality against
/// the flags); any prose count, including this one, is a copy that can drift. A stale invite therefore
/// lands the user in the conversation with the call rendered as a call event,
/// which is honest, rather than joining them to a room nobody is in.
///
/// **A TAP CAN ARRIVE BEFORE DART EXISTS.** On a cold start from a killed app,
/// iOS delivers the tap and *then* the engine spins up. So a tap with no
/// listener is HELD, not dropped, and drained when Dart subscribes. One slot,
/// not a list — unlike the token waiters above, where each caller owns a
/// continuation that must not be lost. Here the value is a navigation intent and
/// the newest one is the only correct destination.
final class NotificationTapChannel: NSObject, FlutterStreamHandler {
  static let shared = NotificationTapChannel()

  private var sink: FlutterEventSink?

  /// A tap that arrived with nobody listening yet. See the cold-start note above.
  private var pending: String?

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterEventChannel(
      name: "cc.imagineering.aikoChatApp/notifications/taps",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(self)
  }

  /// Called from the `UNUserNotificationCenterDelegate` with the tapped
  /// notification's `userInfo`.
  func tapped(userInfo: [AnyHashable: Any]) {
    guard let channelId = userInfo["c"] as? String, !channelId.isEmpty else {
      // Not a call notification, or a payload shape we do not understand. Say so
      // rather than routing somewhere arbitrary — a wrong destination is worse
      // than none, and this line is the only evidence a reader would ever get.
      os_log("[tap] notification tapped with no usable `c` key; not routing", log: aikoCallLog, type: .error)
      return
    }
    if let sink = sink {
      sink(channelId)
    } else {
      pending = channelId
    }
  }

  func onListen(
    withArguments _: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    if let held = pending {
      pending = nil
      events(held)
    }
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

/// The CallKit ring — the thing that makes an incoming call take over a locked
/// handset instead of arriving as silence (Nick, 2026-09-09: *"ringing like a
/// telephone is non-negotiable"*).
///
/// **THIS OBJECT IS WHAT MAKES ARMING VoIP SAFE.** `PushKitTokenChannel.start`
/// takes one as a parameter, so a registry armed with nothing to report to is
/// unconstructable rather than merely unwise (#3609, design 16 v2 §1).
///
/// ## The obligation, and why every path below reports
///
/// Since iOS 13 every VoIP push must be reported to CallKit **before the
/// delivery handler returns**. Failing terminates the app, and repeated failures
/// make the system stop delivering VoIP pushes to this app **on this device** —
/// a per-device denial APNs never reports, because it keeps answering `200`.
///
/// Measured on a handset 2026-09-12 (claude-tasks#4278), which is what lets the
/// end path below be a decision rather than a guess:
///
/// - **Enforcement is a CONSECUTIVE-violation counter that any successful report
///   RESETS.** Four consecutive unreported pushes terminated; five interleaved
///   with reports never did. The earlier "three unreported pushes" was a
///   tolerance window read as a rate — it is a **run length**.
/// - **`reportNewIncomingCall` then immediately `reportCall(endedAt:)` COUNTS as
///   reported.** Seven consecutive, no termination.
/// - **`reportCall(with:endedAt:)` against a LIVE ring RETRACTS it** — but
///   whether that alone *counts as reported* is **UNMEASURED**, because the arm
///   ran interleaved and an interleaved shape provably cannot punish anything.
final class CallKitRinger: NSObject {
  static let shared = CallKitRinger()

  private let provider: CXProvider

  /// Channel id → the call currently ringing for it, and when we reported it.
  ///
  /// **DEVICE-LOCAL, because the wire carries no call id.** The island's payload
  /// is `{"aps": …, "c": <channel>, "k": <kind>}` — there is nothing to key an
  /// end wake on but the channel, so the mapping has to live here (option (b),
  /// agreed with the island tab: correct under both push-type paths and it adds
  /// nothing to the wire).
  ///
  /// **IN UserDefaults, NOT IN MEMORY, and that is the whole point.** A VoIP
  /// push RELAUNCHES a terminated app, so the process that reported the invite
  /// is routinely not the process that receives the hangup. An in-memory map
  /// would be empty exactly when the end wake arrives on a cold start, which is
  /// the case this mechanism exists for.
  private static let liveCallsKey = "callkit.liveCalls"

  /// How long a mapping may be trusted.
  ///
  /// **The island owns the ring ceiling** (Nick, 2026-09-09, reversing design
  /// 12's Decision 1c) and **that lease is not on the wire** — claude-tasks#4233,
  /// the third clock. So this cannot be derived, only bounded: past this, assume
  /// the ring is gone and take the safe path below. Deliberately LONGER than any
  /// plausible lease, because the cost of over-trusting is one extra buzz and
  /// the cost of under-trusting is a ring that never stops.
  private static let liveCallTrustWindow: TimeInterval = 120

  /// How long an ANSWERED call's mapping may be trusted.
  ///
  /// **AN ANSWERED ENTRY IS CLEARED ONLY BY A LIVE PROCESS**, and that is the gap.
  /// `CXEndCallAction`, `providerDidReset` and Dart's `endSystemCall` all need this
  /// app to be running. Force-quit mid-call — or any termination that does not
  /// route through CallKit — and the entry outlives its call in UserDefaults with
  /// nothing left that could ever remove it. Unbounded, it then reads as a live
  /// call forever: the duplicate guard ends every future genuine invite on that
  /// channel and the handset cannot be rung there again, by anyone, short of a
  /// reinstall. (Maxwell, cage-match PR #201 round 1.)
  ///
  /// **BOTH DIRECTIONS FAIL, SO THIS PICKS WHICH FAILURE.** Too short and a real
  /// call's mapping expires underneath it — the phantom the `answered` flag was
  /// added to remove. Too long and a stranded entry blocks calls for that long.
  /// Eight hours is past any call a person actually has and bounds the stranded
  /// case to a day rather than to forever. It is a bound, not a measurement, and
  /// it is deliberately NOT derived from anything — the call's real lease is not
  /// on the wire (claude-tasks#4233, the third clock), same as the ring's.
  private static let answeredCallTrustWindow: TimeInterval = 8 * 60 * 60

  private override init() {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    // Explicit rather than defaulted. The iOS 26.5 SDK header says this defaults
    // to YES; stating it makes the intent legible and means a future SDK default
    // flip cannot silently change whether calls land in Recents. The product
    // question of WHETHER they should is design 16 v2 §6a and is unfilled.
    config.includesCallsInRecents = true
    provider = CXProvider(configuration: config)
    super.init()
    provider.setDelegate(self, queue: nil)
  }

  // MARK: The total function on `k`

  /// Handle one VoIP delivery. **Every path reports before calling `completion`.**
  ///
  /// **PERMISSIVE DECODE, AND IT IS A CROSS-REPO OBLIGATION** (design 16 v2 §7c).
  /// Read the keys we know, ignore the rest, never fail closed on an unexpected
  /// one. The island's ability to add fields later without a payload version bump
  /// rests entirely on this property of code that lives only here — nothing goes
  /// red if a later reader "tidies" it into a strict decoder, and it surfaces a
  /// year later as *"why can't we add a field?"*.
  func handle(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
    let channel = payload["c"] as? String
    let kind = payload["k"] as? String

    switch kind {
    case "call_invite" where channel?.isEmpty == false:
      reportInvite(channel: channel, completion: completion)
    case "call_invite":
      // AN INVITE WITH NO CHANNEL CANNOT BE ANSWERED, so it must not sustain —
      // the same rule the `default` arm below states, applied to the arm that
      // was quietly exempt from it (Tesla, cage-match PR #201).
      //
      // Both shapes were broken and they broke differently. A MISSING `c` rang
      // with no mapping, so answering hit the `guard` and failed: a doorbell
      // that cannot open, ringing until the user kills it. An EMPTY `c` was
      // worse — `if let` accepts `""`, so it mapped, and answering FULFILLED
      // while Dart's decoder (correctly) drops an empty channel: a CONNECTED
      // call with nobody on the other end of the wire. On an unsigned payload
      // that is a repeatable lock-screen weapon, and it cost one `where`.
      os_log("[callkit] call_invite with no usable `c`; reporting and ending", log: aikoCallLog, type: .error)
      reportAndEndImmediately(reason: .failed, completion: completion)
    case "call_end":
      reportEnd(channel: channel, completion: completion)
    default:
      // UNKNOWN OR MISSING — report, then immediately end. NEVER sustain.
      //
      // This is the load-bearing row of §7c's table: a third WakeKind added
      // island-side can never become a spurious ring on an older build. It
      // degrades into the momentary cell, which is a malformed-input failure
      // mode rather than a destination a design routes callers into.
      reportAndEndImmediately(reason: .failed, completion: completion)
    }
  }

  private func reportInvite(channel: String?, completion: @escaping () -> Void) {
    // A DUPLICATE DELIVERY OF A RING ALREADY ON SCREEN, and it is the whole
    // bug of 2026-09-20. This handset carries two VoIP tokens on the island —
    // a live one and a stale one left by an earlier install — so one call
    // fanned out as two pushes, and the device reported two incoming calls in
    // the same millisecond:
    //
    //     12:42:09.664  Received reportNewIncomingCallWithUUID …
    //     12:42:09.664  Received reportNewIncomingCallWithUUID …
    //
    // `maximumCallsPerCallGroup = 1`, so the second report FAILED — and its
    // error handler called `forgetLiveCall(for: channel)`, deleting the
    // mapping that belonged to the FIRST call, which was ringing perfectly
    // well. Answering then hit the `guard` in the answer handler, `fail()`ed,
    // and the user got "Call Failed" and no app. Every symptom of the day.
    //
    // NOT the tradeoff `rememberLiveCall` names. That one is two DIFFERENT
    // calls sharing a channel, which the wire genuinely cannot express and
    // which is deliberately left undefended until the call id ships inside the
    // envelope. This is ONE call arriving twice, which the wire expresses
    // exactly — same channel, same invitation — and which the island cannot
    // deduplicate for us, because two tokens are two devices from where it
    // stands.
    //
    // REPORTED AND ENDED rather than dropped, because must-report is not
    // optional: every VoIP push owes CallKit a call. `reportAndEndImmediately`
    // mints its own throwaway UUID and never touches the map, so the live ring
    // keeps its mapping and stays answerable. It is the measured-safe shape
    // (see `reportEnd`), and the good report that just landed has reset the
    // consecutive-violation counter — one duplicate on a reset counter cannot
    // reach a threshold of four. The cost is a momentary buzz on the duplicate.
    // ANY live entry, ringing OR answered — the guard is `liveCall` and it has to
    // stay `liveCall`. `maximumCallsPerCallGroup = 1`, so while an entry is live
    // there is no second call to mint under any circumstances, and the only
    // question is whether we notice before or after CallKit refuses.
    //
    // ROUND 2 CORRECTION, AND IT WAS MY OWN ROUND-1 FIX. Round 1 narrowed this to
    // a ring-only query (`liveRing`) to stop a stranded answered entry from
    // blackholing a channel. That fixed the symptom at the wrong joint and opened
    // a worse hole, because a LATE duplicate (the stale token's push, delayed)
    // can land AFTER the answer:
    //
    //   entry = {uuidA, answered: true}      a real call, in progress
    //   liveRing → nil                       an answered entry is not a ring
    //   rememberLiveCall(uuidB)              OVERWRITES the live call's mapping
    //   reportNewIncomingCall(uuidB) fails   maximumCallsPerCallGroup = 1
    //   forgetLiveCall(onlyIf: uuidB)        matches what remember just wrote —
    //                                        DELETES the live call's entry
    //
    // and the call in progress is then unhangupable: `endSystemCall` finds no
    // UUID, so the system call is never ended and `disarm()` never runs. That is
    // precisely the defect `7878a61` exists to fix, reintroduced by its own repair.
    //
    // The real defect was never the QUERY, it was the LIFETIME — see
    // `answeredCallTrustWindow`. Bound the entry; leave the guard alone.
    if let channel, liveCall(for: channel) != nil {
      os_log("[callkit] duplicate invite for a ring already live on %{public}@", log: aikoCallLog, type: .info, channel)
      reportAndEndImmediately(reason: .remoteEnded, completion: completion)
      return
    }
    let uuid = UUID()
    let update = CXCallUpdate()
    // Tier 3 of design 12 Decision 6's three tiers: the placeholder. It names the
    // PRODUCT, not a person (Nick, 2026-08-30) — a wrong name on a locked screen
    // is worse than no name. Tiers 1 and 2 (the App Group name cache, and
    // reportCall(with:updated:) once Dart is up) are not built yet.
    update.remoteHandle = CXHandle(type: .generic, value: "Aiko")
    update.hasVideo = true

    // Recorded BEFORE the report, not in its completion. If iOS terminates this
    // process during the report, the end wake that follows must still find the
    // UUID of the ring that is on screen — and the end wake is routinely handled
    // by a different process than the invite.
    if let channel { rememberLiveCall(uuid, for: channel) }

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      // SCOPED TO THE UUID WE JUST STORED, not to the channel. Forgetting by
      // channel alone let a FAILED report evict a DIFFERENT, live call's
      // mapping — a cleanup that tidied away somebody else's call. Belt and
      // braces with the duplicate guard above: that stops the second report
      // happening, this stops any failed report reaching past its own call.
      if error != nil, let channel {
        self.forgetLiveCall(for: channel, onlyIf: uuid)
      }
      completion()
    }
  }

  /// A hangup arrived. **Two paths, and the branch is chosen so that the arm
  /// with an UNMEASURED must-report status is only ever taken when the counter
  /// has provably just been reset.**
  ///
  /// - **A ring we believe is live** → `reportCall(endedAt:)` alone. Measured to
  ///   retract the ring, and **silent** — no buzz on a normal hangup. Its
  ///   must-report status is unmeasured, and that is acceptable here and ONLY
  ///   here: a live mapping exists only because an invite wake reported
  ///   successfully moments ago, and a successful report resets the counter. One
  ///   violation on a reset counter cannot reach a threshold of four.
  ///
  /// - **No live ring — a LONE END** (invite throttled, expired, or the device
  ///   was off) → the measured-safe `reportNewIncomingCall` + immediate end.
  ///   Costs a momentary buzz on a call that was never announced, and buys the
  ///   guarantee where it is actually needed.
  ///
  /// **THE LONE END IS THE DANGEROUS SHAPE AND THIS IS WHY THE BRANCH EXISTS.**
  /// The island tab named it within the hour of the measurement landing: four
  /// consecutive lone ends, each "optimised" into a bare `endedAt` against
  /// nothing, is four consecutive violations with no good report between — the
  /// one production path to per-device denial. And the island MANUFACTURES that
  /// shape under load, because the per-recipient wake budget throttles invites
  /// while ends still go out (claude-tasks#4233/#4265). So the safe arm is bound
  /// to exactly the input that produces it, rather than to a preference.
  private func reportEnd(channel: String?, completion: @escaping () -> Void) {
    guard let channel, let live = liveCall(for: channel) else {
      reportAndEndImmediately(reason: .remoteEnded, completion: completion)
      return
    }
    provider.reportCall(with: live, endedAt: Date(), reason: .remoteEnded)
    forgetLiveCall(for: channel, onlyIf: live)
    // MUST DISARM, and this path is why `disarm()` had only two call sites.
    // `reportCall(endedAt:)` deliberately does NOT round-trip through our
    // `CXEndCallAction` delegate (see `endSystemCall` — the echo loop), so the
    // delegate's `disarm()` never runs for a remote hangup. The class doc states
    // the rule three lines above the enum — "every exit must disarm... worse than
    // the bug being fixed, because it needs no CallKit call to reproduce and
    // nothing reports it" — and this exit did not. The echo fix and the disarm
    // rule were each right alone and never checked against each other.
    // (Tesla, cage-match PR #201 round 1 — the finding of the panel.)
    //
    // CONDITIONAL, because this caller is channel-scoped and `disarm()` is not.
    // See `disarmIfNoCallRemains` (round 3).
    disarmIfNoCallRemains()
    completion()
  }

  private func reportAndEndImmediately(
    reason: CXCallEndedReason, completion: @escaping () -> Void
  ) {
    let uuid = UUID()
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: "Aiko")
    provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
      guard error == nil else {
        // THE FAILURE THIS PATH EXISTS TO PREVENT, AND IT WAS SILENT.
        //
        // This function's whole justification is must-report: every VoIP push
        // owes CallKit a call. But the duplicate arm of `reportInvite` calls it
        // EXACTLY when a call is already live on screen, and
        // `maximumCallsPerCallGroup = 1` — so this report meets the same limit
        // that made the second report fail on 2026-09-20 and started the bug.
        //
        // Both of the documented claims are therefore in question and only one
        // can be true: either the report lands (must-report satisfied, and the
        // "momentary buzz" is real and is what Nick is seeing), or it fails
        // (no buzz, and must-report is NOT satisfied on a path that says it is).
        // Nothing in this code could previously tell you which, which is the
        // exact silent-failure class the whole of 2026-09-20 was spent deleting.
        //
        // `.error` so it survives a level filter, and the reason is interpolated
        // `%{public}@` because the unified log redacts arguments by default.
        // This does not FIX must-report — it makes the question answerable, which
        // is the precondition for measuring the flash at all.
        // (Carnot + Maxwell, cage-match PR #201 round 1.)
        os_log(
          "[callkit] reportAndEndImmediately — report REFUSED, must-report NOT satisfied: %{public}@",
          log: aikoCallLog, type: .error, error!.localizedDescription)
        return completion()
      }
      // INSIDE the report's completion, deliberately. Ending before the report
      // has landed races "unknown UUID" against SpringBoard, and the losing side
      // of that race is a ring nothing ever stops.
      self?.provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
      completion()
    }
  }

  // MARK: What Dart can ask of the system call

  /// Dart is done with this channel's call — it left the room, the join failed,
  /// or it answered the same call in-app. End the system call so the OS is not
  /// left showing a connected call with nothing behind it.
  ///
  /// **A NO-OP BY CONSTRUCTION when there is no system call**, which is what
  /// makes it safe to call unconditionally from Dart's one teardown path. An
  /// outgoing call, or a call placed while the app was foreground and never
  /// pushed, has no entry in the map and nothing happens here.
  ///
  /// `reportCall(endedAt:)` rather than a `CXEndCallAction` transaction through
  /// `CXCallController`, and the reason is the echo. A requested end round-trips
  /// through our own `CXEndCallAction` delegate, which would emit `ended` back to
  /// the Dart half that just asked for this — a loop to break rather than a
  /// sequence to follow. The cost is the reason enum: `.remoteEnded` is the
  /// closest member and it is not literally true (nobody remote ended it). There
  /// is no "this app's own UI ended it" case; the Recents entry is the one
  /// place a reader could notice.
  func endSystemCall(channel: String) {
    guard let live = liveCall(for: channel) else { return }
    provider.reportCall(with: live, endedAt: Date(), reason: .remoteEnded)
    // SCOPED, like every other cleanup: `live` is the UUID this path just read,
    // and `rememberLiveCall` is last-writer-wins, so an invite landing between
    // the read and the forget would otherwise have its mapping deleted by a
    // teardown that did not create it. The rule `onlyIf:` exists for, applied at
    // the site that already holds the UUID. (Maxwell, cage-match PR #201.)
    forgetLiveCall(for: channel, onlyIf: live)
    // THE ORDINARY HANGUP, and it never disarmed. This is Dart's one teardown
    // path — the user left the room, the join failed, they answered in-app — and
    // it ends the call with `reportCall(endedAt:)` precisely so it does NOT echo
    // back through `CXEndCallAction`. Which is also the only place `disarm()` ran.
    // So after any CallKit-answered call ended this way the process stayed in
    // manual mode with audio disabled, and every later in-app call was silent
    // with nothing to report it — until the app restarted.
    // (Tesla, cage-match PR #201 round 1.)
    //
    // CONDITIONAL, because this caller is channel-scoped and `disarm()` is not.
    // See `disarmIfNoCallRemains` (round 3).
    disarmIfNoCallRemains()
  }

  // MARK: The device-local channel → UUID map

  /// The channel a live call UUID belongs to — the map read BACKWARDS.
  ///
  /// The forward direction answers the hangup path ("is this channel ringing?");
  /// this direction answers the answer path ("what is the user answering?"),
  /// because a `CXAnswerCallAction` carries a UUID and nothing else. The map is
  /// at most one entry deep in practice (`maximumCallsPerCallGroup = 1`), so the
  /// scan is not worth a second index.
  private func channel(for uuid: UUID) -> String? {
    for (channel, entry) in stored() where entry.uuid == uuid.uuidString {
      return channel
    }
    return nil
  }

  /// The call this channel is ringing for, or has been ANSWERED for.
  ///
  /// **THE TRUST WINDOW BOUNDS A RING, AND AN ANSWERED CALL IS NOT A RING.**
  /// `liveCallTrustWindow` is a bound on how long to believe in a ring whose
  /// lease is not on the wire. Applied to an ANSWERED call it measures the wrong
  /// lifetime entirely: a three-minute conversation is ordinary, and until this
  /// carried `answered` the map went silent at T+120s underneath a live call —
  /// so Dart's leave path found no UUID, `endSystemCall` became a no-op, and the
  /// OS kept a CONNECTED call that Dart believed it had buried. The phantom the
  /// whole Dart→Swift direction exists to prevent, on every call over two
  /// minutes. (Tesla, cage-match PR #201 — the best finding of the panel.)
  ///
  /// So the window is scoped to the state it was reasoned about: an UNANSWERED
  /// entry is trusted for 120s, an ANSWERED one until something ends it. This is
  /// not a longer window; it is the same window applied only to the thing it
  /// describes.
  private func liveCall(for channel: String) -> UUID? {
    guard
      let entry = stored()[channel],
      let uuid = UUID(uuidString: entry.uuid)
    else { return nil }
    let age = Date().timeIntervalSince1970 - entry.at
    // Two windows, because they bound two different things: a RING's lease, and a
    // CALL's. Applying the ring's 120s to an answered call was the phantom bug;
    // applying NO window to it was the blackhole bug. Each state gets the bound
    // that describes it.
    let window = entry.answered ? Self.answeredCallTrustWindow : Self.liveCallTrustWindow
    guard age < window else { return nil }
    return uuid
  }

  /// Return the process to automatic audio management, but ONLY once no call is
  /// left to need it.
  ///
  /// **`disarm()` IS PROCESS-WIDE AND THESE CALLERS ARE CHANNEL-SCOPED**, which is
  /// the mismatch. `reportEnd` and `endSystemCall` are driven by a channel id, and
  /// the map can hold more channels than CallKit holds calls — `map[channel]` is
  /// written per channel and `maximumCallsPerCallGroup = 1` constrains CallKit, not
  /// this dictionary. So a stale entry for channel B, plus a `call_end` push for B
  /// arriving during a real armed call on channel A, would have ended B's mapping
  /// and then torn the audio session out from under A: `useManualAudio = false` and
  /// `isAudioEnabled = false` mid-conversation, on a call nobody ended.
  ///
  /// Round 1 added those two `disarm()` calls to fix Tesla's finding — every exit
  /// must disarm — and applied the rule at the new sites without checking that the
  /// SITE's scope matched the RULE's scope. The rule is about the last exit, not
  /// about every exit.
  ///
  /// `CXEndCallAction` and `providerDidReset` stay UNCONDITIONAL and should: the
  /// first is CallKit-driven under a one-call limit, and the second is the system
  /// telling us every call is gone. (Maxwell, cage-match PR #201 round 3, against
  /// his own round-1 fix.)
  private func disarmIfNoCallRemains() {
    guard stored().isEmpty else {
      os_log(
        "[audio] disarm withheld — %d call mapping(s) still live", log: aikoCallLog,
        type: .info, stored().count)
      return
    }
    CallAudioSession.disarm()
  }

  private func rememberLiveCall(_ uuid: UUID, for channel: String) {
    var map = stored()
    // LAST WRITER WINS, and the loser is ORPHANED rather than ended. Two
    // overlapping calls in one channel is a state the wire cannot currently
    // express — `c` names a channel, not a call — so the second invite's end
    // wake would end the second call and leave the first ringing to its lease.
    // Named rather than defended: it resolves properly only when the call id
    // ships inside the sealed envelope (design 16 v2 §4c), and defending it here
    // would be a guard on a coupling that the wire should remove.
    map[channel] = (
      uuid: uuid.uuidString, at: Date().timeIntervalSince1970, answered: false
    )
    write(map)
  }

  /// This channel's call has been ANSWERED, so its mapping stops aging out.
  ///
  /// Written from the `CXAnswerCallAction` handler, and deliberately BEFORE the
  /// action is fulfilled — an entry that expires mid-call is the defect this
  /// flag exists to remove, so it must not depend on anything downstream of the
  /// answer succeeding.
  private func markAnswered(channel: String) {
    var map = stored()
    guard let entry = map[channel] else { return }
    map[channel] = (uuid: entry.uuid, at: entry.at, answered: true)
    write(map)
  }

  /// Drop [channel]'s mapping — unconditionally, or only when it still names
  /// [onlyIf].
  ///
  /// The guarded form exists because a failed `reportNewIncomingCall` used to
  /// clear this map by channel, which on a duplicate push deleted the entry of
  /// the call that was ringing successfully. A cleanup is only entitled to
  /// remove what it put there.
  private func forgetLiveCall(for channel: String, onlyIf uuid: UUID? = nil) {
    var map = stored()
    if let uuid, map[channel]?.uuid != uuid.uuidString { return }
    map.removeValue(forKey: channel)
    write(map)
  }

  private func stored() -> [String: (uuid: String, at: TimeInterval, answered: Bool)] {
    let raw = UserDefaults.standard.dictionary(forKey: Self.liveCallsKey) ?? [:]
    var out: [String: (uuid: String, at: TimeInterval, answered: Bool)] = [:]
    for (channel, value) in raw {
      guard
        let entry = value as? [String: Any],
        let uuid = entry["uuid"] as? String,
        let at = entry["at"] as? TimeInterval
      else { continue }  // Permissive here too: a malformed entry is not a live call.
      // `answered` DEFAULTS FALSE, which is what an entry written by the
      // previous build has. Defaulting it true would resurrect every stale
      // mapping on that device as an un-aging one.
      out[channel] = (
        uuid: uuid, at: at, answered: entry["answered"] as? Bool ?? false
      )
    }
    return out
  }

  private func write(_ map: [String: (uuid: String, at: TimeInterval, answered: Bool)]) {
    var raw: [String: Any] = [:]
    for (channel, entry) in map {
      raw[channel] = ["uuid": entry.uuid, "at": entry.at, "answered": entry.answered]
    }
    UserDefaults.standard.set(raw, forKey: Self.liveCallsKey)
  }
}

/// What the SYSTEM CALL UI did, handed to Dart — and the one thing Dart can ask
/// of it back (claude-tasks#4420).
///
/// **THE RING WITHOUT THIS IS A DOORBELL ON AN EMPTY HOUSE.** `CallKitRinger`
/// makes a locked handset ring; every part of actually *being on a call* — the
/// island's room token, the LiveKit connection, the camera — lives in Dart. This
/// is the seam between them, and it is deliberately two-way:
///
/// - **Swift → Dart** (`/call/actions`): the user answered, or the user hung up
///   in the system UI. On a locked handset the system UI is the ONLY way out of
///   a call, so the `ended` direction is not a nicety — without it the room
///   stays joined after the user presses the red button.
/// - **Dart → Swift** (`/call/control`): Dart's call is over, so end the system
///   call. Without this, a join that fails leaves the OS showing a CONNECTED
///   call with no media behind it, and that phantom outlives the app.
///
/// **A LIST, NOT A SLOT, and this is where it differs from
/// `NotificationTapChannel`.** That one holds the newest tap because a tap is a
/// DESTINATION and only the newest is correct. These are TRANSITIONS: answer
/// then end is a call that was taken and hung up, and keeping only the newest
/// would be indistinguishable from a hangup for a call that was never answered.
/// Replayed in order, they leave Dart in the state the user actually produced.
///
/// **THE COLD-START CASE IS THE NORMAL ONE.** A VoIP push relaunches a
/// terminated app; the user can answer before the Flutter engine finishes
/// booting, let alone before Dart restores a session. So an action with nobody
/// listening is HELD, exactly like a tap, and drained when Dart subscribes.
final class SystemCallChannel: NSObject, FlutterStreamHandler {
  static let shared = SystemCallChannel()

  /// The transitions Dart is told about. **A CLOSED SET, not free text** — Dart
  /// parses these back into a sealed type, so a new member is a compile-time
  /// event on one side and a `default:` on the other.
  enum Action: String {
    case answered
    case ended
  }

  private var sink: FlutterEventSink?

  /// Actions that arrived with nobody listening yet. See the cold-start note.
  private var pending: [[String: String]] = []

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterEventChannel(
      name: "cc.imagineering.aikoChatApp/call/actions",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(self)

    FlutterMethodChannel(
      name: "cc.imagineering.aikoChatApp/call/control",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      switch call.method {
      case "endSystemCall":
        guard
          let args = call.arguments as? [String: Any],
          let channel = args["channel"] as? String, !channel.isEmpty
        else {
          // Dart asked to end SOMETHING and did not say what. Ending the wrong
          // call is worse than ending none, and answering `nil` lets the Dart
          // side's own error path say so.
          return result(
            FlutterError(
              code: "no-channel",
              message: "endSystemCall requires a non-empty `channel`",
              details: nil))
        }
        CallKitRinger.shared.endSystemCall(channel: channel)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// [origin] names WHICH native event produced this, for the report only —
  /// Dart branches on `action`, never on this. `ended` covers a
  /// `CXEndCallAction` (somebody ended the call) and `providerDidReset` (the
  /// system tore our provider down and every call with it), which mean opposite
  /// things and were the same byte on this channel until 2026-09-20: a handset
  /// rang, was never answered, and lost its call 2.1 seconds later, and no
  /// report could say which of the two had happened.
  func emit(action: Action, channel: String, origin: String = "") {
    var event = ["action": action.rawValue, "channel": channel]
    if !origin.isEmpty { event["origin"] = origin }
    if let sink = sink {
      sink(event)
    } else {
      pending.append(event)
    }
  }

  func onListen(
    withArguments _: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    let held = pending
    pending = []
    held.forEach { events($0) }
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

extension CallKitRinger: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    // The system tore down every call we had. The map now describes nothing, and
    // a stale entry here would make the next end wake take the silent arm
    // against a ring that no longer exists — i.e. the unmeasured path on a
    // counter we cannot vouch for.
    //
    // TELL DART BEFORE FORGETTING, for every channel the map still names. A
    // reset is the one end that arrives with no action and no UUID to match, so
    // a live call screen would otherwise stay mounted over a room the OS has
    // already torn the audio out from under.
    for (channel, _) in stored() {
      SystemCallChannel.shared.emit(
        action: .ended, channel: channel, origin: "providerReset")
    }
    os_log("[callkit] providerDidReset — the system tore down every call we had", log: aikoCallLog, type: .info)
    UserDefaults.standard.removeObject(forKey: Self.liveCallsKey)
    // A reset is the end that arrives with no action and no UUID, so it is the
    // one path that would otherwise strand the process in manual mode with no
    // `CXEndCallAction` ever coming to release it.
    CallAudioSession.disarm()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    // THE ANSWER IS A HANDOFF, NOT A CONNECTION. Everything that actually makes
    // a call — the island token, the room, the camera — lives in Dart, so all
    // this can do is name the channel and let the Dart half join it. See
    // `SystemCallChannel` for why the answer survives Dart not existing yet.
    guard let channel = channel(for: action.callUUID) else {
      // No mapping, so nothing to join: there is no other carrier of the
      // channel id, and the room IS the channel. `fail()` rather than
      // `fulfill()` — fulfilling would present a connected call that can never
      // carry media, and a call that visibly fails is the honest render of a
      // call we cannot place. Only reachable if the map was cleared between the
      // report and the answer (`providerDidReset`, or a reinstall).
      os_log("[callkit] answered a call with no channel mapping; failing the action", log: aikoCallLog, type: .error)
      action.fail()
      return
    }
    // BEFORE fulfilling: from here the entry describes a CALL, not a ring, and
    // must stop aging out from under the teardown path.
    markAnswered(channel: channel)
    // BEFORE the emit, not after: the emit is what sends Dart to join the room,
    // and joining is what creates the audio track. Arming after it would be a
    // race whose losing side is a track that took the session under automatic
    // management before manual mode was in force — i.e. exactly today's bug,
    // reproduced intermittently instead of always. See `CallAudioSession`.
    // THE STATE "ARMED, AUDIO DISABLED, CONFIGURATION FAILED" HAD NO NAME AND NO
    // EXIT. `arm()` logged the failure and returned, the emit went out, and the
    // action was fulfilled anyway — so CallKit had nothing to activate,
    // `didActivate` never arrived, `isAudioEnabled` stayed false, and the user got
    // a CONNECTED, SILENT call. That is precisely the defect `0657cae` exists to
    // remove, reachable through its own error path.
    // (Carnot, cage-match PR #201 round 3.)
    guard CallAudioSession.arm() else {
      os_log(
        "[callkit] audio session could not be configured; failing the answer rather than presenting a silent call",
        log: aikoCallLog, type: .error)
      // Back to automatic management before leaving — otherwise this failure
      // strands the process in manual mode, which is the durable break the class
      // doc calls worse than the bug being fixed.
      CallAudioSession.disarm()
      // `fail()`, not `fulfill()`, on the file's own stated rule for the mapping
      // case: "fulfilling would present a connected call that can never carry
      // media, and a call that visibly fails is the honest render of a call we
      // cannot place." The rejected alternative was to disarm and fulfil anyway,
      // letting WebRTC manage the session automatically — plausible, but it trades
      // a loud failure for a possibly-silent call, which is the exact trade this
      // whole day was spent reversing.
      action.fail()
      return
    }
    SystemCallChannel.shared.emit(
      action: .answered, channel: channel, origin: "answerAction")
    os_log("[callkit] CXAnswerCallAction fulfilled for channel %{public}@", log: aikoCallLog, type: .info, channel)
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // The handoff this class exists for. Without it CallKit owns an activated
    // session that WebRTC never learns about, and the call is silent.
    CallAudioSession.didActivate(audioSession)
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    CallAudioSession.didDeactivate(audioSession)
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    // Says the call ENDED. It does NOT say who ended it — user, system timeout,
    // or our own reportCall. An earlier spike logged this as "ended by user" and
    // that label, inherited verbatim, produced a confident wrong reading that
    // survived a night of self-corroboration (claude-tasks#4278). Record what
    // happened; leave why to whoever has the timestamps.
    //
    // WHOEVER ended it, Dart has to hear about it: this is the hangup button on
    // the lock screen and in the system call UI, and it is the ONLY way out of
    // a call answered from a locked handset. Emitted before the mapping is
    // forgotten, because the channel is what identifies the call to Dart.
    for (channel, entry) in stored() where entry.uuid == action.callUUID.uuidString {
      SystemCallChannel.shared.emit(
        action: .ended, channel: channel, origin: "endAction")
      // SCOPED, and the `where` above is NOT a substitute for it. That clause
      // matches against a SNAPSHOT from `stored()`; `forgetLiveCall` then takes
      // its OWN read and deletes by channel, so an invite landing between the two
      // reads is deleted by a teardown that matched the entry it replaced. Round 1
      // of this cage-match looked at this site and waved it through on exactly
      // that reasoning — "it already matched on entry.uuid" — which confuses
      // matching a snapshot with deleting under the match.
      // (Kelvin, cage-match PR #201 round 2 — the site Maxwell dismissed.)
      forgetLiveCall(for: channel, onlyIf: action.callUUID)
    }
    os_log("[callkit] CXEndCallAction performed for %{public}@", log: aikoCallLog, type: .info, action.callUUID.uuidString)
    // Unconditional, and deliberately OUTSIDE the loop: a hangup whose UUID
    // matches no stored entry still ends whatever CallKit call was live, and
    // leaving the process in manual mode would silently break the in-app ring
    // path from here on — a durable break outliving the call that caused it.
    // Disarming a call that never armed is a no-op (see `CallAudioSession`).
    CallAudioSession.disarm()
    action.fulfill()
  }
}

/// The PushKit VoIP token, handed to Dart so the island can ring this handset
/// like a telephone (Nick, 2026-09-09: "ringing like a telephone is
/// non-negotiable").
///
/// A SECOND, INDEPENDENT REGISTRY — not a variant of [ApnsTokenChannel]. It has
/// its own token, its own rotation callbacks, and its own permission story, and
/// conflating the two is how a device ends up registered under the wrong
/// `token_kind` and simply never rings.
///
/// **THE PERMISSION ASYMMETRY IS THE PART THAT SURPRISES.** A PushKit VoIP token
/// requires NO user permission at all; an APNs alert token requires granted
/// notification permission. So a user who declines notifications has a VoIP
/// token and will never have an alert token — "reachable for calls, unreachable
/// for messages" is a NORMAL, permanent state to model, not an error to log.
/// The reverse pairing is normal too, on a device that has never run this build.
///
/// **NO TOKEN IS MINTED BY THIS BUILD.** The channels below are registered and
/// the plumbing is complete, but nothing arms the registry — see the note where
/// `start()` used to be. So `currentToken` answers nil, no VoIP row is ever
/// registered island-side, and no VoIP push can be sent to this device.
///
/// An earlier version of this comment asserted the opposite — "registered
/// unconditionally at launch... a token that only exists once the user opens a
/// call screen is a token the island cannot ring" — which described the
/// INTENDED end state as though it were the current one. That argument is sound
/// and it is not yet implemented; leaving it here read as a design already in
/// force, which is how the next reader adds the one line that arms VoIP delivery
/// with nothing to report to.
final class PushKitTokenChannel: NSObject, PKPushRegistryDelegate {
  static let shared = PushKitTokenChannel()

  private var registry: PKPushRegistry?
  private var sink: FlutterEventSink?

  /// Set by [start] in the same statement that arms the registry, so it is
  /// non-nil whenever a push can arrive. Not optional-by-design — optional
  /// only because it cannot be an `init` parameter on a `shared` singleton.
  private var ringer: CallKitRinger?

  /// The last token handed to Dart, so a re-registration reporting the SAME
  /// value is not published as a rotation — the same reason [ApnsTokenChannel]
  /// keeps one.
  private var lastReported: String?

  /// Callers of `currentToken` waiting on the first delegate callback. A LIST,
  /// not one slot, for the reason spelled out on [ApnsTokenChannel.waiters]: a
  /// dropped continuation is a Dart future that never completes and a device
  /// never registered.
  private var waiters: [(String?) -> Void] = []

  func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(
      name: "cc.imagineering.aikoChatApp/pushkit",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "currentToken": self.currentToken(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
    FlutterEventChannel(
      name: "cc.imagineering.aikoChatApp/pushkit/refreshes",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(self)
  }

  /// Arm VoIP delivery, **taking the thing that will answer for it**.
  ///
  /// Constructing a `PKPushRegistry` and assigning `desiredPushTypes` is the ONLY
  /// thing that makes iOS deliver VoIP pushes to this app. Armed with nothing to
  /// report to, the first push terminates the process, and repeated failures make
  /// the system stop delivering VoIP pushes to this app **on this device** — a
  /// denial APNs never reports, because it keeps answering `200`.
  ///
  /// **THE PARAMETER IS THE SAFETY PROPERTY.** An earlier revision had a bare
  /// `start()` sitting unused, resting on the fact that nothing called it.
  /// Kelvin, cage-match round 1: *"the only thing preventing this is the prayer
  /// that start() is never called — that's not engineering."* Correct, so the
  /// method was deleted outright rather than left guarded by convention, and it
  /// comes back only now, in the same increment as [CallKitRinger], shaped so the
  /// bad state cannot be written down: there is no way to arm the registry
  /// without handing over the object that discharges the obligation.
  ///
  /// Idempotent, because a VoIP push can itself relaunch the app and run
  /// `didFinishLaunchingWithOptions` again.
  func start(reportingTo ringer: CallKitRinger) {
    guard registry == nil else { return }
    self.ringer = ringer
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry
  }

  private func currentToken(_ result: @escaping FlutterResult) {
    if let token = lastReported { return result(token) }
    // NOT STARTED — answer nil NOW, never queue. There is no PushKit analogue of
    // `didFailToRegisterForRemoteNotifications`, so a waiter parked here has
    // nothing that can ever drain it. That is not a stall, it is permanent:
    // `DeviceRegistrar.start()` awaits this call with `_refreshes` already
    // non-null, and its idempotency guard then turns every LATER `start()` into
    // a no-op — the whole pairing wedged for the life of the process, silently,
    // including the ALERT token that works today.
    guard let registry else { return result(nil) }
    if let data = registry.pushToken(for: .voIP) {
      let hex = PushKitTokenChannel.hex(data)
      lastReported = hex
      return result(hex)
    }
    // Started but not minted yet. Waiting is right — a nil here is
    // indistinguishable to Dart from "this device has no VoIP token" — but it is
    // BOUNDED, for the same reason: iOS may simply never call back, and an
    // unbounded wait wedges the caller rather than failing.
    waiters.append { result($0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
      guard let self, !self.waiters.isEmpty, self.lastReported == nil else { return }
      self.drainWaiters(with: nil)
    }
  }

  private static func hex(_ data: Data) -> String {
    // RAW bytes as lowercase hex. Never `data.description`, for the reason the
    // APNs path documents: the island stores whatever we send and a mismatch
    // only ever surfaces as silence.
    data.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: PKPushRegistryDelegate

  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let token = PushKitTokenChannel.hex(credentials.token)
    // THE ONE VALUE YOU NEED TO RING THIS HANDSET, AND IT WAS INVISIBLE. The
    // token is handed to Dart and registered island-side, and nowhere on the
    // device could you read it — so `tool/voip_push.py`, an instrument built
    // precisely to put a chosen payload on a chosen handset, had no way to learn
    // the handset. Measuring the call path required a value the call path never
    // said out loud.
    //
    // It is an opaque, device-scoped id, not user-authored content, so it sits
    // inside the same rule the channel ULIDs and call UUIDs here do. It is not a
    // secret on its own: ringing this device also needs the APNs signing key,
    // which is the thing actually kept out of the log.
    os_log("[pushkit] voip token %{public}@", log: aikoCallLog, type: .info, token)
    let isRotation = lastReported != nil && lastReported != token
    lastReported = token
    drainWaiters(with: token)
    if isRotation { sink?(token) }
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    lastReported = nil
    drainWaiters(with: nil)
  }

  /// A VoIP push arrived. **Reporting to CallKit here is MANDATORY before the
  /// completion handler returns** — iOS terminates the app otherwise, and
  /// repeated failures make the system stop delivering VoIP pushes to this app
  /// on this device (Apple, PKPushRegistryDelegate; per-device denial of
  /// delivery, not a revoked entitlement).
  ///
  /// REACHABLE, AND THIS COMMENT USED TO SAY THE OPPOSITE. It read "unreachable
  /// in this build, structurally: nothing constructs a PKPushRegistry (there is
  /// no `start()`)" — while `start(reportingTo:)` sits 40 lines above and
  /// `application(_:didFinishLaunchingWithOptions:)` calls it unconditionally at
  /// every launch. The note was true when written and nothing retired it, so the
  /// file asserted its own most load-bearing path was dead code. A reader
  /// trusting it would conclude a real VoIP delivery could not happen here — on
  /// the exact handset that rang, answered and carried audio on 2026-09-20.
  ///
  /// It is deliberately NOT a `fatalError`. If the invariant above were somehow
  /// broken, crashing here produces the same app termination iOS would impose
  /// anyway, while also burning the crash as our own — and a deliberate crash on
  /// a user's handset is a worse answer than a log the next build can find.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else { return completion() }
    guard let ringer else {
      // UNREACHABLE BY CONSTRUCTION: `start(reportingTo:)` is the only thing that
      // arms this registry and it sets `ringer` in the same call. Kept, and
      // deliberately NOT a `fatalError`: if the invariant ever broke, crashing
      // here produces the same termination iOS would impose anyway while also
      // burning it as our own crash, and a deliberate crash on a user's handset
      // is a worse answer than a line the next build can find.
      //
      // **BUT IT STILL REPORTS**, and that is the part that was missing (Tesla,
      // cage-match PR #201). This was the one path in the file that returned
      // from a VoIP delivery without reporting to CallKit — and consecutive
      // unreported deliveries are exactly what buys per-device VoIP denial, the
      // worst state in this system and one APNs never tells us about. An
      // impossible branch that violates the platform contract IF it happens is
      // not made safe by the argument that it will not happen; `unreachable` is
      // a claim, and the obligation is a rule. Routing an empty payload through
      // `handle` lands on its `default` arm — report, then end immediately —
      // which is the measured-safe discharge and never sustains a ring.
      os_log("[pushkit] armed with no ringer — see #3609", log: aikoCallLog, type: .error)
      return CallKitRinger.shared.handle(payload: [:], completion: completion)
    }
    ringer.handle(payload: payload.dictionaryPayload, completion: completion)
  }

  private func drainWaiters(with token: String?) {
    let pending = waiters
    waiters = []
    for waiter in pending { waiter(token) }
  }
}

extension PushKitTokenChannel: FlutterStreamHandler {
  func onListen(
    withArguments _: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Claim the delegate BEFORE super, so a cold launch caused by a tap is not
    // delivered to nobody. `didReceive` fires after the delegate is set, and on
    // a tap-launch iOS calls it once the app finishes launching.
    UNUserNotificationCenter.current().delegate = self
    // ARM VoIP AT LAUNCH, not when a call screen opens. A token that only exists
    // once the user has opened the call UI is a token the island cannot ring —
    // and the whole point is reaching a handset whose owner is not looking at it.
    // Safe to do this early because the registry cannot be armed without the
    // ringer that discharges the must-report obligation.
    PushKitTokenChannel.shared.start(reportingTo: CallKitRinger.shared)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ApnsTokenChannel") {
      ApnsTokenChannel.shared.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "NotificationTapChannel")
    {
      NotificationTapChannel.shared.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "PushKitTokenChannel")
    {
      PushKitTokenChannel.shared.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "SystemCallChannel")
    {
      SystemCallChannel.shared.register(with: registrar)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // The RAW device token as lowercase hex — 64 characters for a standard APNs
    // token. Never `deviceToken.description`, which on older SDKs produced
    // `<a1b2 c3d4 ...>` and on newer ones produces something else entirely; the
    // island stores whatever we send and the mismatch would only ever surface as
    // silence.
    ApnsTokenChannel.shared.received(
      token: deviceToken.map { String(format: "%02x", $0) }.joined()
    )
    super.application(
      application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    ApnsTokenChannel.shared.failed()
    super.application(
      application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}

// NOT `extension AppDelegate: UNUserNotificationCenterDelegate`.
// `FlutterAppDelegate` ALREADY declares that conformance, so restating it is a
// "Redundant conformance" compile error — one that neither `flutter analyze`
// nor the Dart suite can see, because both stop at the language boundary. This
// file's own methods are `override`s for exactly that reason.
extension AppDelegate {
  /// The user tapped a notification. The ONLY reason this class exists.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    NotificationTapChannel.shared.tapped(
      userInfo: response.notification.request.content.userInfo)
    super.userNotificationCenter(
      center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// A notification arriving while the app is FOREGROUND.
  ///
  /// Returns no presentation options, which PRESERVES today's behaviour rather
  /// than changing it: with no delegate installed iOS suppresses the banner for
  /// a foregrounded app, and claiming the delegate would otherwise silently
  /// alter that for every notification type, not just calls. A foregrounded app
  /// already receives the invite over the websocket and draws `RingOverlay`, so
  /// a banner would double the same event.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }
}
