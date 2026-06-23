import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Blend the system title bar into the dark app: transparent + no title text,
    // dark chrome, and a window background matching the app's AppBar
    // (CcColors.panel #25272B) so the thin title strip (traffic lights) reads as
    // one with the app instead of a light "outer frame". No fullSizeContentView,
    // so the traffic lights stay in their own strip and never overlap the toolbar.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.appearance = NSAppearance(named: .darkAqua)
    self.backgroundColor = NSColor(
      red: 37.0 / 255.0, green: 39.0 / 255.0, blue: 43.0 / 255.0, alpha: 1.0)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
