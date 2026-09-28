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

class MainFlutterWindow: NSWindow {
  /// Below this the editor's panels would overflow (WindowChrome.minimumSize in Dart).
  static let minimumSize = NSSize(width: 960, height: 620)

  private var windowChannel: FlutterMethodChannel?
  private let opener = DocumentOpener()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.contentMinSize = MainFlutterWindow.minimumSize
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
    opener.channel = channel
    (NSApp.delegate as? FlutterAppDelegate)?.addApplicationLifecycleDelegate(opener)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
