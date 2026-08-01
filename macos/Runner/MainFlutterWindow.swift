import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // The macOS title bar otherwise shows CFBundleName ("aiko_chat_app", the
    // Dart package name). Set the human-facing product name explicitly — this
    // overrides the bundle-name default without renaming the .app binary.
    self.title = "Aiko Chat"
  }
}
