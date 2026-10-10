import Cocoa
import FlutterMacOS

/// Files opened from the Finder (double-click, Open With, dropped on the Dock icon), handed to
/// Dart over the window channel. A file that launches the app arrives before Dart runs, so
/// they wait until Dart asks for them (`takePendingFiles`).
final class DocumentOpener: NSObject, FlutterAppLifecycleDelegate {
  var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var dartListening = false

  @objc(handleOpenURLs:) func handleOpen(_ urls: [URL]) -> Bool {
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    if paths.isEmpty { return false }
    if dartListening, let channel = channel {
      channel.invokeMethod("openFiles", arguments: paths)
    } else {
      pending += paths
    }
    return true
  }

  func takePending() -> [String] {
    dartListening = true
    defer { pending = [] }
    return pending
  }
}

/// The system's Fonts panel, for a music font that isn't embedded (font_settings.dart, the
/// `curated_score/fonts` channel). The panel stays open beside the window, as it does in every
/// app; the family chosen in it is answered when it closes (nil when none was).
final class FontPicker: NSObject {
  private var result: FlutterResult?
  private var start: NSFont?
  private var chosen: String?

  func pick(family: String?, result: @escaping FlutterResult) {
    self.result?(nil) // an earlier pick still open: it ends here
    self.result = result
    chosen = nil
    let manager = NSFontManager.shared
    start = family.flatMap { manager.font(withFamily: $0, traits: [], weight: 5, size: 24) } ?? NSFont.systemFont(ofSize: 24)
    manager.target = self
    manager.action = #selector(changeFont(_:))
    manager.setSelectedFont(start!, isMultiple: false)
    let panel = manager.fontPanel(true)!
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(panelClosed(_:)), name: NSWindow.willCloseNotification, object: panel)
    panel.makeKeyAndOrderFront(nil)
  }

  @objc func changeFont(_ sender: Any?) {
    guard let manager = sender as? NSFontManager, let start = start else { return }
    let family = manager.convert(start).familyName
    chosen = family == start.familyName ? nil : family
  }

  @objc private func panelClosed(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    if NSFontManager.shared.target === self { NSFontManager.shared.target = nil }
    result?(chosen)
    result = nil
  }
}

class MainFlutterWindow: NSWindow {
  /// Below this the editor's panels would overflow (WindowChrome.minimumSize in Dart).
  static let minimumSize = NSSize(width: 960, height: 620)

  /// The first window's size, when nothing is remembered: at most 90% of the screen's usable
  /// area (a 13-inch laptop), never below [minimumSize]. After that the window reopens where
  /// and as big as it was left.
  static let initialSize = NSSize(width: 1440, height: 900)
  private static let frameName = "Curator"

  private var windowChannel: FlutterMethodChannel?
  private var fontChannel: FlutterMethodChannel?
  private let fontPicker = FontPicker()
  private let opener = DocumentOpener()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.contentMinSize = MainFlutterWindow.minimumSize
    if !self.setFrameUsingName(MainFlutterWindow.frameName) {
      let visible = (self.screen ?? NSScreen.main)?.visibleFrame.size ?? MainFlutterWindow.initialSize
      let size = NSSize(
        width: max(MainFlutterWindow.minimumSize.width, min(MainFlutterWindow.initialSize.width, visible.width * 0.9)),
        height: max(MainFlutterWindow.minimumSize.height, min(MainFlutterWindow.initialSize.height, visible.height * 0.9)))
      self.setFrame(self.frameRect(forContentRect: NSRect(origin: .zero, size: size)), display: true)
      self.center()
    }
    self.setFrameAutosaveName(MainFlutterWindow.frameName)
    self.title = "Curator"

    // The document's name, its edited dot and its proxy icon, set from Dart (window_chrome.dart).
    let channel = FlutterMethodChannel(
      name: "curated_score/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "takePendingFiles" {
        result(self.opener.takePending())
        return
      }
      guard call.method == "setDocument", let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.title = args["title"] as? String ?? "Curator"
      self.isDocumentEdited = args["edited"] as? Bool ?? false
      if let path = args["path"] as? String {
        self.representedURL = URL(fileURLWithPath: path)
      } else {
        self.representedURL = nil
      }
      result(nil)
    }
    windowChannel = channel

    let fonts = FlutterMethodChannel(
      name: "curated_score/fonts", binaryMessenger: flutterViewController.engine.binaryMessenger)
    fonts.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "pickFont" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.fontPicker.pick(family: (call.arguments as? [String: Any])?["family"] as? String, result: result)
    }
    fontChannel = fonts
    opener.channel = channel
    (NSApp.delegate as? FlutterAppDelegate)?.addApplicationLifecycleDelegate(opener)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
