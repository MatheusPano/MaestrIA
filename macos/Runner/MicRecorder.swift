// --- ditado (vocalização) — fora desta versão --------------------------------
//
// A metade nativa do microfone. Ver o cabeçalho de `lib/services/dictation.dart`
// — a conversa por voz não entra neste lançamento, e o arquivo fica comentado
// pra voltar com ela. Ele continua no target do Xcode: comentado, compila pra
// nada, e reativar é só tirar este bloco.

/*
import AVFoundation

/// O microfone da janela, gravando o WAV que o whisper.cpp sabe ler.
///
/// Em processo, e não um `ffmpeg -f avfoundation` shellado, por causa do TCC:
/// um filho nascido de `zsh -lc` dentro da `.app` pede o microfone como um
/// processo sem dono claro, e o pedido ou não produz diálogo nenhum ou produz
/// um em nome de outra coisa. O sintoma é o pior que existe -- grava, não dá
/// erro, e o arquivo é silêncio. Pedindo daqui, o diálogo sai em nome da
/// Maestria (com o texto do `NSMicrophoneUsageDescription`) e a permissão fica
/// registrada nas Preferências, onde dá pra revogar.
///
/// O formato é o que o whisper.cpp exige na entrada: PCM 16 bits, 16 kHz, mono.
/// O microfone entrega float a 44,1 ou 48 kHz, então há um [AVAudioConverter]
/// no meio -- reamostrar aqui é mais barato que gravar 48 kHz e reamostrar
/// depois, e evita um segundo arquivo em disco com a voz de alguém.
final class MicRecorder {
  private let engine = AVAudioEngine()

  /// O arquivo aberto enquanto se grava. Nulo é o estado parado -- e anulá-lo
  /// é o que fecha o WAV: o `AVAudioFile` volta e escreve o tamanho no
  /// cabeçalho quando é liberado.
  private var file: AVAudioFile?
  private var url: URL?

  /// A escrita acontece na thread de render do áudio e a parada vem da main.
  /// `removeTap` não promete que o callback em voo já voltou, e um write num
  /// arquivo que a main acabou de fechar é um crash dentro do CoreAudio.
  private let lock = NSLock()

  var isRecording: Bool { engine.isRunning }

  enum Failure: LocalizedError {
    case noInput
    case unsupported

    var errorDescription: String? {
      switch self {
      case .noInput: return "nenhum microfone disponível"
      case .unsupported: return "o formato do microfone não pôde ser convertido"
      }
    }
  }

  func start(path: String) throws {
    if engine.isRunning { return }
    let target = URL(fileURLWithPath: path)
    let input = engine.inputNode
    let inFormat = input.inputFormat(forBus: 0)
    // Sem permissão -- ou sem entrada nenhuma -- o nó existe e descreve um
    // formato de zero hertz. Instalar um tap nele não falha; só nunca chama.
    guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Failure.noInput }
    guard
      let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: inFormat, to: outFormat)
    else { throw Failure.unsupported }

    let opened = try AVAudioFile(
      forWriting: target,
      settings: outFormat.settings,
      commonFormat: .pcmFormatInt16,
      interleaved: true)
    file = opened
    url = target

    input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
      self?.write(buffer, through: converter, as: outFormat)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      // Um tap pendurado num engine que não subiu ficaria lá pra sempre, e a
      // próxima tentativa cairia no `installTap` sobre um bus já ocupado.
      input.removeTap(onBus: 0)
      close()
      throw error
    }
  }

  /// Fecha o microfone e devolve o caminho do que foi gravado.
  @discardableResult
  func stop() -> String? {
    guard engine.isRunning else { return nil }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    let path = url?.path
    close()
    return path
  }

  /// Desiste: para e apaga, sem deixar a voz de ninguém no /tmp.
  func cancel() {
    let path = stop()
    if let path { try? FileManager.default.removeItem(atPath: path) }
  }

  private func close() {
    lock.lock()
    file = nil
    lock.unlock()
    url = nil
  }

  /// Um bloco do microfone, reamostrado e escrito.
  ///
  /// O `convert` com mudança de taxa é o que exige a forma com bloco: o
  /// conversor puxa quantos blocos de entrada precisar pra encher a saída, e
  /// o nosso só tem um pra dar -- daí o `noDataNow` na segunda chamada.
  private func write(
    _ buffer: AVAudioPCMBuffer, through converter: AVAudioConverter, as format: AVAudioFormat
  ) {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

    var offered = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if offered {
        status.pointee = .noDataNow
        return nil
      }
      offered = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, out.frameLength > 0 else { return }

    lock.lock()
    defer { lock.unlock() }
    try? file?.write(from: out)
  }
}
*/
