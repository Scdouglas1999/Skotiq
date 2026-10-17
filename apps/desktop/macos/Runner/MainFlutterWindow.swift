import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The window is one slate of content: no title bar band, content laid
    // out under the native traffic lights, which the shell leaves room for
    // at the sidebar's top-left (see ShellChromeMetrics.sidebarDragStrip
    // HeightMacOS). The title is hidden but still set so Mission Control
    // and the window menu name the window correctly.
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.styleMask.insert(.fullSizeContentView)

    // The shell's window-chrome channel. The one question it answers is what
    // a title-bar double click does, which on macOS is the
    // AppleActionOnDoubleClick default ("Maximize" / "Minimize" / "None").
    let channel = FlutterMethodChannel(
      name: "com.skotiq.desktop/window_chrome",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getTitlebarDoubleClickAction":
        result(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick"))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
