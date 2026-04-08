import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Hide window and dock icon — app lives in menu bar
    self.orderOut(nil)
    NSApp.setActivationPolicy(.accessory) // Hide from dock
    return false
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    NSApp.setActivationPolicy(.regular) // Show in dock when window visible
    super.makeKeyAndOrderFront(sender)
  }
}
