import Cocoa
import FlutterMacOS
import UserNotifications
import os

class MainFlutterWindow: NSWindow {
  // Held for the window's life: the channel handler and the notification
  // delegate both point back into it.
  private var desktopRing: DesktopRing?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    desktopRing = DesktopRing(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()

    // The bundle's own name is "Aiko Chat" now (PRODUCT_NAME, #390), so this
    // only states what the default would already be.
    self.title = "Aiko Chat"

    // Floor the window so the responsive chat layout always has room for the
    // wide rail or a comfortable narrow column (below 720pt logical it collapses
    // to the phone layout anyway — this is ergonomic, not correctness-critical).
    self.minSize = NSSize(width: 640, height: 480)
  }
}

/// The Mac's ring: the parts a phone's OS supplies on its own — a sound, a
/// notification you can click, and a Dock icon that will not stop bouncing.
/// Dart drives it from the ring state (`lib/features/call/application/
/// desktop_ring.dart`); this side only renders it.
///
/// The SOUND plays whenever something rings: the in-app ring is silent on every
/// platform, and on a Mac nothing else makes one. The NOTIFICATION and the
/// BOUNCE happen only while the app is not frontmost — in front, the ring
/// banner is already in view — and both are withdrawn the moment it becomes
/// frontmost, or the ring ends.
final class DesktopRing: NSObject, UNUserNotificationCenterDelegate {
  private static let noteId = "aiko.ring"
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var sound: NSSound?
  private var attention: Int?
  private var becameActive: NSObjectProtocol?
  // Whether a banner is still WANTED. Posting is asynchronous (it waits on the
  // authorization answer), so the app can become frontmost — or the ring end —
  // between the decision to post and the post. Checked on the main thread right
  // before the add and again after it, so a withdraw that lands in either gap
  // still wins.
  private var bannerWanted = false
  // Readable with `log show --predicate 'subsystem == "cc.imagineering.aikoChatApp"'`,
  // unlike the Dart side's telemetry in a release build (#223).
  private let log = Logger(subsystem: "cc.imagineering.aikoChatApp", category: "ring")

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(name: "aiko/desktop_ring", binaryMessenger: messenger)
    self.window = window
    super.init()
    UNUserNotificationCenter.current().delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "start":
        let args = call.arguments as? [String: Any] ?? [:]
        self.start(
          title: args["title"] as? String ?? "Incoming call",
          body: args["body"] as? String ?? "")
        result(nil)
      case "stop":
        self.stop()
        result(nil)
      case "prepare":
        self.prepare()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    becameActive = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.log.info("became active")
      self?.withdraw()
    }
  }

  deinit {
    if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
  }

  private func start(title: String, body: String) {
    // From the asset catalog: tool/make_ringtone.dart writes it.
    if sound == nil, let data = NSDataAsset(name: "Ring")?.data, let s = NSSound(data: data) {
      s.loops = true
      sound = s
    }
    if sound?.isPlaying == false { sound?.play() }
    log.info("start active=\(NSApp.isActive, privacy: .public) sound=\(self.sound != nil, privacy: .public)")
    guard !NSApp.isActive else { return }
    if attention == nil { attention = NSApp.requestUserAttention(.criticalRequest) }
    post(title: title, body: body)
  }

  private func stop() {
    log.info("stop")
    sound?.stop()
    withdraw()
  }

  /// Take back everything that exists only to get the user to the window.
  private func withdraw() {
    bannerWanted = false
    if let attention { NSApp.cancelUserAttentionRequest(attention) }
    attention = nil
    clearBanners()
  }

  /// ALL of them, not this id: the Mac app posts no other notifications (it
  /// has no push), and removal by identifier left a delivered ring banner in
  /// place on hardware (2026-10-19).
  private func clearBanners() {
    let center = UNUserNotificationCenter.current()
    center.removeAllPendingNotificationRequests()
    center.removeAllDeliveredNotifications()
    log.info("banners cleared")
  }

  /// Ask once, at sign-in (Dart calls this), never on a ring: on the first ring
  /// the prompt competed with the call, and dismissing it in a hurry is a
  /// lasting "no" (2026-10-19). A refusal costs the banner only — the sound and
  /// the bounce need no permission.
  private func prepare() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { [weak self] settings in
      self?.log.info("prepare: status=\(settings.authorizationStatus.rawValue, privacy: .public)")
      guard settings.authorizationStatus == .notDetermined else { return }
      center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
        self?.log.info("prepare: authorized=\(granted, privacy: .public)")
      }
    }
  }

  private func post(title: String, body: String) {
    bannerWanted = true
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert]) { granted, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.log.info("authorized=\(granted, privacy: .public) wanted=\(self.bannerWanted, privacy: .public)")
        guard granted, self.bannerWanted, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Same id every time: a newer caller replaces the banner, never stacks.
        center.add(UNNotificationRequest(identifier: Self.noteId, content: content, trigger: nil)) { _ in
          // A withdraw that landed while the add was in flight: take it back.
          DispatchQueue.main.async { [weak self] in
            guard let self, !self.bannerWanted || NSApp.isActive else { return }
            self.clearBanners()
          }
        }
      }
    }
  }

  // Clicked: bring the ring banner into view. Answering stays a deliberate
  // second click on the banner, so a stray click on a notification can never
  // put the user on camera.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      NSApp.activate(ignoringOtherApps: true)
      self?.window?.makeKeyAndOrderFront(nil)
    }
    completionHandler()
  }

  // Delivered while frontmost (it became active between post and delivery):
  // the banner is already in view, so show nothing.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }
}
