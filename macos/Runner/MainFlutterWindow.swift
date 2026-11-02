import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = NSSize(width: 480, height: 520)
    self.title = "Quran Clipper"

    // Open large enough for the side-by-side editor. macOS state restoration
    // would put back an old frame, so it's off; the frame autosave below
    // remembers the size the user leaves the window at instead.
    self.isRestorable = false
    let visible = (self.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    self.setContentSize(NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 80)))
    self.center()
    self.setFrameAutosaveName("QuranClipperMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
