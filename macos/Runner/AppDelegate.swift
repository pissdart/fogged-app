import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var statusItem: NSStatusItem?
  var isConnected = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Create menu bar status item
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    updateStatusIcon()

    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Show Fogged", action: #selector(showWindow), keyEquivalent: ""))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
    statusItem?.menu = menu

    // Listen for VPN status updates from Flutter
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.fogged.vpn/tray", binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] (call, result) in
        if call.method == "setConnected" {
          self?.isConnected = call.arguments as? Bool ?? false
          self?.updateStatusIcon()
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func updateStatusIcon() {
    if let button = statusItem?.button {
      button.title = isConnected ? "F●" : "F○"
    }
  }

  @objc func showWindow() {
    NSApp.setActivationPolicy(.regular)
    if let window = mainFlutterWindow {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  @objc func quitApp() {
    NSApp.terminate(nil)
  }
}
