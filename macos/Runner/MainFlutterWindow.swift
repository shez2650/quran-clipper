import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // The window sizes itself to its content view, so give the Flutter view
    // the size we want before attaching it.
    let visible = (self.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 80))
    flutterViewController.view.frame = NSRect(origin: .zero, size: size)
    self.contentViewController = flutterViewController
    self.setContentSize(size)
    self.center()
    self.contentMinSize = NSSize(width: 480, height: 520)
    self.title = "Quran Clipper"
    // Remember the size and position the user leaves it at.
    self.setFrameAutosaveName("QuranClipperMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { n in
      NSLog("QuranClipper resized: %@", NSStringFromRect((n.object as! NSWindow).frame))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      for w in NSApp.windows {
        NSLog("QuranClipper window %@ visible=%d frame=%@", String(describing: type(of: w)), w.isVisible ? 1 : 0, NSStringFromRect(w.frame))
      }
    }
  }
}
