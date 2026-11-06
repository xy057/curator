import Cocoa
import FlutterMacOS
import Vision

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

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  /// Below this the editor's panels would overflow (WindowChrome.minimumSize in Dart).
  static let minimumSize = NSSize(width: 960, height: 620)

  /// The first window's size, when nothing is remembered: at most 90% of the screen's usable
  /// area (a 13-inch laptop), never below [minimumSize]. After that the window reopens where
  /// and as big as it was left.
  static let initialSize = NSSize(width: 1440, height: 900)
  private static let frameName = "Curator"

  private var windowChannel: FlutterMethodChannel?
  private var fontChannel: FlutterMethodChannel?
  private var textChannel: FlutterMethodChannel?
  private let fontPicker = FontPicker()
  private let opener = DocumentOpener()

  override func awakeFromNib() {
    // Projects are tabs inside the one window (project_tabs.dart): AppKit's own window tabs are
    // off, so View has no Show Tab Bar / Show All Tabs of its own beside the app's.
    NSWindow.allowsAutomaticWindowTabbing = false
    self.tabbingMode = .disallowed
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
    self.delegate = self

    // The document's name, its edited dot and its proxy icon, set from Dart (window_chrome.dart).
    let channel = FlutterMethodChannel(
      name: "curated_score/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "takePendingFiles" {
        result(self.opener.takePending())
        return
      }
      // The Dock icon while the app runs: the mascot's PNG, or nil for the bundle's icon.
      if call.method == "setAppIcon" {
        let png = (call.arguments as? [String: Any])?["png"] as? FlutterStandardTypedData
        NSApp.applicationIconImage = png.flatMap { NSImage(data: $0.data) }
        result(nil)
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
    let text = FlutterMethodChannel(
      name: "curated_score/ocr", binaryMessenger: flutterViewController.engine.binaryMessenger)
    text.setMethodCallHandler { call, result in
      guard call.method == "read", let args = call.arguments as? [String: Any],
        let rgba = args["rgba"] as? FlutterStandardTypedData, let width = args["width"] as? Int,
        let height = args["height"] as? Int
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      PageText.read(rgba: rgba.data, width: width, height: height, result: result)
    }
    textChannel = text
    opener.channel = channel
    (NSApp.delegate as? FlutterAppDelegate)?.addApplicationLifecycleDelegate(opener)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// The close button quits, as Quit does: Dart offers to save unsaved changes first
  /// (`_exitRequested` in main.dart) while the window is still there to ask in. Left to close,
  /// the window would be gone before the quit that follows could ask.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }
}

/// The words on a picture of a page (a scanned PDF score's, which has no text of its own), read
/// by Vision on the Mac itself: each line's text and box, as fractions of the picture from its
/// top left, `[text, x, y, width, height]`.
enum PageText {
  static func read(rgba: Data, width: Int, height: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let lines = recognise(rgba: rgba, width: width, height: height)
      DispatchQueue.main.async {
        if let lines = lines {
          result(lines)
        } else {
          result(FlutterError(code: "unreadable", message: "Couldn’t read the page’s text", details: nil))
        }
      }
    }
  }

  private static func recognise(rgba: Data, width: Int, height: Int) -> [[Any]]? {
    guard width > 0, height > 0, rgba.count >= width * height * 4,
      let provider = CGDataProvider(data: rgba as CFData),
      let page = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
      // On white: the page is drawn on nothing, and Vision would read its ink on black.
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(page, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    // A staff's name is small beside a whole page: Vision's default leaves out text under a
    // 32nd of its height.
    request.minimumTextHeight = 0.004
    let wanted = ["en-US", "it-IT", "de-DE", "fr-FR", "es-ES", "pt-BR"]
    if let supported = try? request.supportedRecognitionLanguages() {
      let languages = wanted.filter { supported.contains($0) }
      if !languages.isEmpty { request.recognitionLanguages = languages }
    }
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return nil
    }
    return (request.results ?? []).compactMap { line in
      guard let text = line.topCandidates(1).first?.string else { return nil }
      let box = line.boundingBox  // from the bottom left
      return [text, Double(box.minX), Double(1 - box.maxY), Double(box.width), Double(box.height)]
    }
  }
}
