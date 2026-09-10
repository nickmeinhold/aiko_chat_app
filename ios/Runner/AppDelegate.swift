import Flutter
import UIKit
import PushKit
import UserNotifications

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
      NSLog("[tap] notification tapped with no usable `c` key; not routing")
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
/// Registered unconditionally at launch rather than behind the calling gate:
/// `desiredPushTypes` is what makes iOS mint the token, and a token that only
/// exists once the user opens a call screen is a token the island cannot ring.
/// The island refuses to send to a device it has no VoIP row for, which is the
/// gate that actually holds.
final class PushKitTokenChannel: NSObject, PKPushRegistryDelegate {
  static let shared = PushKitTokenChannel()

  private var registry: PKPushRegistry?
  private var sink: FlutterEventSink?

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

  /// Begin registration. Idempotent.
  func start() {
    guard registry == nil else { return }
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    // Assigning `desiredPushTypes` is what triggers minting. Nothing else does.
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
  /// NOT WIRED YET — the CXProvider path is the next increment. Until it exists
  /// this method must not be reachable, which is why the island only sends VoIP
  /// to a device that registered a `voip` token, and this build registers one
  /// only once there is something to report to.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    NSLog("[pushkit] VoIP push received with no CXProvider wired — see #3609")
    completion()
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
