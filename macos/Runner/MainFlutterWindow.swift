import Cocoa
import FlutterMacOS
import Quartz

/// What Quick Look is being asked to show. One file at a time: the result
/// strip previews the row you clicked, not the whole list.
class QuickLookSource: NSObject, QLPreviewPanelDataSource {
  var url: NSURL?

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    return url == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    return url
  }
}

class MainFlutterWindow: NSWindow {
  /// Held by the window because that is who Quick Look asks. The shared panel
  /// walks the responder chain looking for a controller, so the data source
  /// has to outlive the method call that set it.
  private let quickLook = QuickLookSource()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The dock badge: how many sessions are waiting on you, readable from
    // whatever app you are in. There is no Flutter API for it, and it is four
    // lines of AppKit.
    let channel = FlutterMethodChannel(
      name: "maestria/dock",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "badge":
        let label = call.arguments as? String
        NSApp.dockTile.badgeLabel = (label?.isEmpty ?? true) ? nil : label
        result(nil)
      case "isActive":
        result(NSApp.isActive)
      case "quickLook":
        // The files a session produces for someone who does not write code
        // are PDFs, spreadsheets and images. The OS already renders every one
        // of them, and a preview costs nothing to close -- which is the whole
        // difference between glancing at a result and opening an editor.
        guard let path = call.arguments as? String,
              FileManager.default.fileExists(atPath: path),
              let panel = QLPreviewPanel.shared()
        else {
          result(false)
          return
        }
        self.quickLook.url = NSURL(fileURLWithPath: path)
        NSApp.activate(ignoringOtherApps: true)
        // Key first: the shared panel picks its controller by walking the
        // responder chain from the key window, and that has to be us.
        self.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        result(true)
      case "chooseFolder":
        // A sheet on our own window. The osascript picker this replaces
        // opened a loose window belonging to another process, which read as
        // the app freezing while it waited for an answer.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        panel.message = "Escolha a pasta do repositório"
        panel.beginSheetModal(for: self) { response in
          result(response == .OK ? panel.url?.path : nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  // Quick Look is driven through the responder chain rather than by whoever
  // opened it: without these three the shared panel finds no controller and
  // opens empty.

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    return true
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = quickLook
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
  }
}
