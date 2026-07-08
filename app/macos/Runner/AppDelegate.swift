import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var fallbackWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    showMainWindow()
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      showMainWindow()
    }
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func showMainWindow() {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }
      let window = self.mainFlutterWindow ?? self.createFallbackWindow()
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func createFallbackWindow() -> NSWindow {
    let flutterViewController = FlutterViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 335, y: 390, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Infinite Agent Platform"
    window.isReleasedWhenClosed = false
    window.contentViewController = flutterViewController
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(
      red: 37.0 / 255.0, green: 39.0 / 255.0, blue: 43.0 / 255.0, alpha: 1.0)

    RegisterGeneratedPlugins(registry: flutterViewController)
    fallbackWindow = window
    mainFlutterWindow = window
    return window
  }
}
