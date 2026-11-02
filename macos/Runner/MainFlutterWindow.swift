import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let autosaveName = "QuranClipperMainWindow"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = NSSize(width: 480, height: 520)
    self.title = "Quran Clipper"

    // First launch: open large enough for the side-by-side editor. After
    // that, macOS restores whatever size the user left it at.
    let firstLaunch = UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.autosaveName)") == nil
    applyDefaultSize()
    self.setFrameAutosaveName(Self.autosaveName)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { n in
      NSLog("QuranClipper resized: %@\n%@", NSStringFromRect((n.object as! NSWindow).frame),
            Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
    }
    if firstLaunch {
      // Something during start-up shrinks the window back to the nib size,
      // so apply the default once more after it has appeared.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.applyDefaultSize() }
    }
  }

  private func applyDefaultSize() {
    let visible = (self.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    self.setContentSize(NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 80)))
    self.center()
  }
}
