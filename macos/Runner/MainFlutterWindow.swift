import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Open large enough for the side-by-side editor, centred on screen.
    let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1280, visible.width - 40), height: min(820, visible.height - 40))
    let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    self.setFrame(NSRect(origin: origin, size: size), display: true)
    self.minSize = NSSize(width: 480, height: 560)
    self.title = "Quran Clipper"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
