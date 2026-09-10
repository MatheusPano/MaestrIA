// --- ditado (vocalização) — fora desta versão -------------------------------
// Ver o cabeçalho de `lib/services/dictation.dart`.
// import AVFoundation
import Cocoa
import FlutterMacOS
import Quartz
import UniformTypeIdentifiers

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

  // --- ditado (vocalização) — fora desta versão -----------------------------
  // Ver o cabeçalho de `lib/services/dictation.dart`.
  //
  // /// O microfone do ditado. Da janela pelo mesmo motivo do Quick Look: ele
  // /// precisa sobreviver à chamada de método que o ligou, e há um só por
  // /// máquina -- ver [Dictation] no lado Dart.
  // private let mic = MicRecorder()

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
      case "chooseMarkdown":
        // A porta pra um documento que o cockpit não viu nascer.
        //
        // A tira de arquivos alterados é o que as ferramentas de escrita
        // anunciaram; um `cat > notas.md`, um arquivo de outro dia ou um que
        // veio de fora não estão lá, e o caminho no scrollback não é
        // clicável. Sheet da nossa janela, como a escolha de pasta.
        let file = NSOpenPanel()
        file.canChooseFiles = true
        file.canChooseDirectories = false
        file.allowsMultipleSelection = false
        file.prompt = "Abrir"
        file.message = "Escolha um markdown pra ler"
        // Começa onde a pessoa está: a pasta do painel em foco.
        if let start = call.arguments as? String, !start.isEmpty {
          file.directoryURL = URL(fileURLWithPath: start)
        }
        // `allowedContentTypes` só existe no 11; o alvo é o 10.15. Texto puro
        // cobre o `.md`, que conforma a ele.
        if #available(macOS 11.0, *) {
          var types: [UTType] = [.plainText]
          if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
          file.allowedContentTypes = types
        } else {
          file.allowedFileTypes = ["md", "markdown", "mdx", "txt"]
        }
        file.beginSheetModal(for: self) { response in
          result(response == .OK ? file.url?.path : nil)
        }
      case "chooseWorkspace":
        // O arquivo do VS Code que lista pastas. Um picker próprio e não o de
        // pasta com arquivos ligados: quem vem por aqui já sabe que quer um
        // arranjo inteiro, e a lista filtrada é o que impede escolher o json
        // errado que está do lado.
        let workspace = NSOpenPanel()
        workspace.canChooseFiles = true
        workspace.canChooseDirectories = false
        workspace.allowsMultipleSelection = false
        workspace.prompt = "Adicionar"
        workspace.message = "Escolha um workspace do VS Code"
        // Não há UTI registrada pra `.code-workspace`; pela extensão o sistema
        // fabrica um tipo dinâmico, que é o bastante pra filtrar.
        if #available(macOS 11.0, *) {
          if let type = UTType(filenameExtension: "code-workspace") {
            workspace.allowedContentTypes = [type]
          }
        } else {
          workspace.allowedFileTypes = ["code-workspace"]
        }
        workspace.beginSheetModal(for: self) { response in
          result(response == .OK ? workspace.url?.path : nil)
        }
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

    // --- ditado (vocalização) — fora desta versão ---------------------------
    // Ver o cabeçalho de `lib/services/dictation.dart`. Sem este handler o
    // canal `maestria/mic` não existe, que é o que o lado Dart já trata como
    // "este build não tem a metade nativa do microfone".

    /*
    // O microfone, num canal só dele. Separado do `maestria/dock` porque o
    // que ele responde é de outra natureza: o dock é um estado que se
    // empurra, este é um dispositivo que se abre e se fecha.
    let micChannel = FlutterMethodChannel(
      name: "maestria/mic",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    micChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "start":
        guard let path = call.arguments as? String else {
          result(FlutterError(code: "path", message: "sem caminho pra gravar", details: nil))
          return
        }
        // Pedir sempre, e não só da primeira vez: já decidido, o sistema
        // responde na hora sem diálogo nenhum, e é assim que uma permissão
        // revogada no meio do caminho vira uma mensagem em vez de um WAV mudo.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async {
            guard granted else {
              result(
                FlutterError(
                  code: "denied",
                  message:
                    "o microfone está bloqueado pra Maestria — Ajustes › Privacidade › Microfone",
                  details: nil))
              return
            }
            do {
              try self.mic.start(path: path)
              result(true)
            } catch {
              result(
                FlutterError(code: "mic", message: error.localizedDescription, details: nil))
            }
          }
        }
      case "stop":
        result(self.mic.stop() != nil)
      case "cancel":
        self.mic.cancel()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    */

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
