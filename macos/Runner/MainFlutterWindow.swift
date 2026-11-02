import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.minSize = NSSize(width: 480, height: 560)
    self.title = "Quran Clipper"
    applyDefaultFrame()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // Flutter's first layout can resize the window, so apply the size again
    // once the app has finished launching.
    DispatchQueue.main.async { [weak self] in self?.applyDefaultFrame() }

    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { n in
      NSLog("QuranClipper resized: %@", NSStringFromRect((n.object as! NSWindow).frame))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      for w in NSApp.windows {
        NSLog("QuranClipper window %@ visible=%d frame=%@", String(describing: type(of: w)), w.isVisible ? 1 : 0, NSStringFromRect(w.frame))
      }
    }
  }

  /// Large enough for the side-by-side editor, centred on screen.
  private func applyDefaultFrame() {
    let visible = (self.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 40))
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    self.setFrame(NSRect(origin: origin, size: size), display: true)
    NSLog("QuranClipper window frame: %@ (screen %@)", NSStringFromRect(self.frame), NSStringFromRect(visible))
  }
}
