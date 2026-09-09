import Flutter
import UIKit
import UserNotifications

// SPIKE ONLY — see the VoipSpike class at the foot of this file.
import CallKit
import PushKit
import os

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

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // SPIKE ONLY — see VoipSpike.swift. Revert with `git branch -D`.
    VoipSpike.shared.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ApnsTokenChannel") {
      ApnsTokenChannel.shared.register(with: registrar)
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

// ============================================================================
// SPIKE ONLY — everything below this line is throwaway. Branch: spike/voip-must-report
// ============================================================================

/// **SPIKE — NOT PRODUCT CODE. This file exists to answer ONE question with a
/// device instead of an argument.**
///
/// > Does `CXProvider.reportCall(with:endedAt:reason:)` ALONE satisfy iOS's
/// > must-report rule, or must every VoIP push produce a
/// > `reportNewIncomingCall`?
///
/// Since iOS 13 a VoIP push must report an incoming call to CallKit before the
/// delivery handler returns, or iOS terminates the app and eventually stops
/// delivering VoIP pushes entirely. Design 16 v2 §7 forks on this and neither
/// tab has observed it: if `endedAt` alone counts, a hangup can ride VoIP and
/// the "stop becomes a start" problem disappears. If it does not, ends must go
/// as alert pushes — and a user who declined notifications has a VoIP token and
/// will NEVER have an alert token, so the ceiling cannot reach exactly the
/// phones that most need it.
///
/// **The arms are chosen by the push payload, not by a build flag**, so one
/// install runs both and the control cannot drift from the experiment.
///
/// - `mode: "report"` — POSITIVE CONTROL. A normal `reportNewIncomingCall`.
///   This arm MUST produce a visible ring. Until it does, a null result from
///   the other arm is a fact about the harness, not about iOS.
/// - `mode: "endonly"` — THE EXPERIMENT. Report NOTHING but an `endedAt` for a
///   UUID iOS has never seen. Predicted to be the arm iOS punishes.
/// - `mode: "silent"` — NEGATIVE CONTROL. Report nothing at all. This arm MUST
///   be punished; it is the undisputed violation. If iOS tolerates even this,
///   the instrument is not measuring must-report on this OS version and NO
///   conclusion may be drawn from `endonly`.
///
/// Read the results with:
///     log stream --predicate 'eventMessage CONTAINS "[VOIP-SPIKE]"'
private let spikeLog = OSLog(subsystem: "cc.imagineering.voipspike", category: "spike")

final class VoipSpike: NSObject {
  static let shared = VoipSpike()

  private var registry: PKPushRegistry?
  private var provider: CXProvider?

  /// Pushes seen since launch. A termination between two sends shows up as this
  /// counter restarting at 1 — which is the *observable* the experiment turns
  /// on, since "iOS killed the app" has no callback.
  private var seen = 0

  func start() {
    let config = CXProviderConfiguration()
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    // Explicit, per design 16 v2 §6 — the iOS 26.5 SDK header says the default
    // is YES, so this is intent made legible rather than defence.
    config.includesCallsInRecents = true

    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    self.provider = provider

    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.registry = registry

    log("started; awaiting VoIP token")
  }

  fileprivate func log(_ message: String) {
    // os_log, NOT NSLog, and the difference decided a night.
    //
    // NSLog is printf-style: it does not understand `%{public}@` and prints the
    // annotation LITERALLY (observed: "[VOIP-SPIKE] {public}@"). And plain
    // NSLog did not reach `idevicesyslog` here at all, though os_log lines from
    // Firebase in the same process did. os_log with an explicit `{public}`
    // qualifier is the combination that is both unredacted and streamable while
    // pushes are arriving — which is what an experiment needs, since
    // `devicectl --console` cannot stay attached across a VoIP relaunch.
    //
    // The general shape: an instrument that is silent for a FORMATTING reason
    // is indistinguishable from an experiment with no result.
    // BOTH, deliberately — they fail differently and each covered the other's
    // blind spot tonight. NSLog reaches stderr, which is what
    // `devicectl --console` captures. os_log reaches the unified log, which is
    // what a syslog relay can stream while pushes arrive. Using os_log ALONE
    // silenced the console; using NSLog alone never reached the relay.
    NSLog("[VOIP-SPIKE] %@", message)
    os_log("[VOIP-SPIKE] %{public}@", log: spikeLog, type: .default, message)
  }
}

extension VoipSpike: PKPushRegistryDelegate {
  func pushRegistry(
    _ registry: PKPushRegistry,
    didUpdate credentials: PKPushCredentials,
    for type: PKPushType
  ) {
    let token = credentials.token.map { String(format: "%02x", $0) }.joined()
    log("VOIP TOKEN \(token)")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didInvalidatePushTokenFor type: PKPushType
  ) {
    log("token invalidated")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    seen += 1
    let dict = payload.dictionaryPayload
    let mode = (dict["mode"] as? String) ?? "report"
    let tag = (dict["tag"] as? String) ?? "-"
    log("push #\(seen) mode=\(mode) tag=\(tag)")

    guard let provider = provider else {
      log("NO PROVIDER — aborting, this is a harness fault not a finding")
      completion()
      return
    }

    let uuid = UUID()

    switch mode {
    case "endonly":
      // THE EXPERIMENT. Report an end for a UUID iOS has never been told about.
      // Deliberately no reportNewIncomingCall anywhere on this path.
      provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
      log("push #\(seen) endonly: reportCall(endedAt:) for unknown \(uuid)")
      completion()

    case "silent":
      // NEGATIVE CONTROL. The undisputed violation. If this is not punished the
      // instrument is blind and `endonly` proves nothing.
      log("push #\(seen) silent: reporting NOTHING")
      completion()

    default:
      // POSITIVE CONTROL. Must ring.
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: "Aiko")
      update.hasVideo = true
      provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        if let error = error {
          self?.log("push #\(self?.seen ?? -1) report FAILED \(error.localizedDescription)")
        } else {
          self?.log("push #\(self?.seen ?? -1) report OK \(uuid)")
        }
        completion()
      }
    }
  }
}

extension VoipSpike: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {
    log("provider reset")
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    log("answered")
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    log("ended by user")
    action.fulfill()
  }
}
