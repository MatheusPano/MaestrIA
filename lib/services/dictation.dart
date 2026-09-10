// --- ditado (vocalização) — fora desta versão -------------------------------
//
// A conversa por voz não entra neste lançamento: o ditado está comentado por
// inteiro, e não removido, pra voltar numa versão futura.
//
// As outras pontas dele levam esta mesma marca — `grep -rn "fora desta versão"`
// acha todas: o store (config, atalho e o [toggleDictation]), o mapa de
// atalhos, o menu do painel, o cabeçalho do painel, a seção de configurações,
// o microfone nativo do macOS (`MicRecorder.swift` e o canal `maestria/mic` em
// `MainFlutterWindow.swift`), a permissão no `Info.plist` e o entitlement de
// entrada de áudio. Reativar é tirar os blocos de comentário de todas elas.

/*
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'paths.dart';
import 'shell.dart';

/// Falar com o claude em vez de digitar: o microfone abre, o whisper.cpp
/// transcreve, e o que saiu de lá é colado no prompt do painel em foco.
///
/// O motor é o `whisper-cli` do whisper.cpp, rodado como qualquer outro
/// programa do usuário -- ver [Sh]. Foi escolhido contra o `SFSpeechRecognizer`
/// do macOS por causa do que se fala aqui dentro: "abre uma worktree do
/// `hotfix/BUG#45902`" é português com nome de branch no meio, e o ditado do
/// sistema transcreve isso como português. Um modelo só, escolhido pelo
/// usuário, também é a única forma de a qualidade ser a mesma nas duas
/// plataformas -- o que um motor nativo por sistema nunca daria.
///
/// O modelo não vem no app: o large-v3-turbo tem 1,6 GB, e uma `.app` não é
/// lugar pra isso. Ele carrega em ~1,5 s e transcreve 7 s de fala em ~0,25 s
/// num M4 -- o custo por ditado é praticamente só a carga, que é o que torna
/// desnecessário trocá-lo por um quantizado menor.
/// Quem dita instala o binário e baixa o `.bin` uma vez -- ver [problem], que
/// é quem diz exatamente o que está faltando.
///
/// A captura é a metade que *não* dá pra shellar no macOS. Um `ffmpeg` nascido
/// de `zsh -lc` dentro da `.app` pede o microfone ao TCC como um processo
/// órfão: o diálogo de permissão ou não aparece, ou aparece em nome de outra
/// coisa, e o que se grava é silêncio digital sem nenhum erro. Então lá o
/// áudio é capturado em processo, pelo `AVAudioEngine` do lado nativo (ver
/// `MainFlutterWindow.swift`), que é o que faz a permissão ser pedida em nome
/// da Maestria e ficar registrada nas Preferências. No Linux não há TCC, e o
/// `parecord` resolve.
class Dictation extends ChangeNotifier {
  Dictation({DictationConfig? config}) : config = config ?? DictationConfig();

  /// A metade nativa da captura. O mesmo desenho do `maestria/dock`: um canal
  /// pequeno pra aquilo que só o AppKit sabe fazer.
  static const _mic = MethodChannel('maestria/mic');

  DictationConfig config;

  DictationPhase get phase => _phase;
  DictationPhase _phase = DictationPhase.idle;

  /// O painel que vai receber o texto -- guardado porque o foco pode andar
  /// enquanto se fala, e o ditado é do painel em que ele começou.
  String? get target => _target;
  String? _target;

  bool get busy => _phase != DictationPhase.idle;

  /// O que este painel está fazendo no ditado, se algo. É o que o cabeçalho
  /// desenha: um painel só sabe de si.
  DictationPhase phaseOf(String tabId) =>
      _target == tabId ? _phase : DictationPhase.idle;

  /// Onde o áudio de uma fala mora enquanto ela não virou texto.
  ///
  /// Vai pro lixo assim que o whisper lê -- ver [end]. O pid no nome é pela
  /// segunda janela: duas maestrias ditando ao mesmo tempo gravariam uma por
  /// cima da outra.
  static File get scratch => File('${Directory.systemTemp.path}/maestria-ditado-$pid.wav');

  /// Abre o microfone pro painel [tabId]. Devolve o motivo de não ter aberto,
  /// ou null quando a gravação começou.
  Future<String?> begin(String tabId) async {
    if (busy) return null;
    // Antes de gravar, e não depois: descobrir que falta o modelo *depois* de
    // alguém falar trinta segundos é perder os trinta segundos.
    if (await problem() case final missing?) return missing;
    final wav = scratch;
    if (wav.existsSync()) wav.deleteSync();
    _target = tabId;
    _phase = DictationPhase.recording;
    notifyListeners();
    final failure = await record(wav);
    if (failure != null) {
      _reset();
      return failure;
    }
    return null;
  }

  /// Fecha o microfone e transcreve. Um dos dois campos vem preenchido.
  Future<({String? text, String? problem})> end() async {
    if (_phase != DictationPhase.recording) return (text: null, problem: null);
    _phase = DictationPhase.transcribing;
    notifyListeners();
    final wav = scratch;
    try {
      if (await endRecording() case final failure?) return (text: null, problem: failure);
      if (!wav.existsSync()) {
        return (text: null, problem: 'o microfone não gravou nada');
      }
      // Meio segundo de áudio não é uma frase, é o segundo toque no atalho
      // chegando junto com o primeiro. O whisper transcreve isso como uma
      // alucinação curta -- "Obrigado.", "Legenda:" --, que é pior do que
      // nada, porque parece que funcionou.
      if (wav.lengthSync() < _floor) {
        return (text: null, problem: 'não deu tempo de ouvir nada');
      }
      // Silêncio nunca chega ao whisper -- ver [peak] pra por quê.
      if (peak(wav) < _audible) {
        return (
          text: null,
          problem: 'o microfone não captou som: gravou silêncio. confira a '
              'entrada em Ajustes › Som › Entrada — um fone sem microfone no '
              'jack vira "Microfone Externo" e assume a entrada sem captar nada',
        );
      }
      final heard = await transcribe(wav);
      if (heard.text case final text? when looping(text)) {
        return (text: null, problem: 'o que voltou foi ruído, não fala: "$text"');
      }
      return heard;
    } finally {
      // O que foi dito não fica em disco esperando alguém achar.
      if (wav.existsSync()) {
        try {
          wav.deleteSync();
        } catch (_) {}
      }
      _reset();
    }
  }

  /// Desiste: fecha o microfone e joga o áudio fora sem transcrever nada.
  Future<void> cancel() async {
    if (!busy) return;
    await endRecording();
    final wav = scratch;
    if (wav.existsSync()) {
      try {
        wav.deleteSync();
      } catch (_) {}
    }
    _reset();
  }

  void _reset() {
    _phase = DictationPhase.idle;
    _target = null;
    notifyListeners();
  }

  /// Meio segundo de PCM 16 kHz mono, mais o cabeçalho do wav.
  static const _floor = 16000 * 2 ~/ 2 + 44;

  /// Abaixo disto, num inteiro de 16 bits, não houve som -- são ~-48 dBFS.
  ///
  /// Baixo de propósito: o que isto precisa pegar é o zero absoluto de uma
  /// entrada morta, não uma fala baixinha. Ruído de sala num microfone vivo
  /// passa disto com folga.
  static const _audible = 128;

  /// A amostra mais alta do wav, em módulo. Zero é silêncio digital.
  ///
  /// Existe porque silêncio é a pior entrada possível pro whisper: sem fala
  /// pra transcrever, ele *continua o `--prompt`* e entra em loop de
  /// repetição. Foi o que aconteceu na primeira vez que isto rodou de verdade,
  /// com um fone sem microfone plugado no jack -- o macOS publica um
  /// "Microfone Externo" que assume a entrada padrão e grava zeros, e o painel
  /// recebeu `Vocabulário: pinjate, pinjate, pinjate…` como se fosse fala. Uma
  /// alucinação convincente é pior que um erro: parece que funcionou.
  ///
  /// O wav é o nosso, então o cabeçalho é conhecido -- PCM 16 bits mono, 44
  /// bytes de cabeçalho. Não é um leitor de wav, é a leitura deste wav.
  @visibleForTesting
  static int peak(File wav) {
    final bytes = wav.readAsBytesSync();
    if (bytes.length <= 44) return 0;
    final samples = bytes.buffer.asInt16List(
      bytes.offsetInBytes + 44,
      (bytes.length - 44) ~/ 2,
    );
    var loudest = 0;
    for (final sample in samples) {
      final level = sample < 0 ? -sample : sample;
      if (level > loudest) loudest = level;
    }
    return loudest;
  }

  // --- o que falta pra ditar -----------------------------------------------

  /// Por que não dá pra ditar agora -- ou null, se der.
  ///
  /// As duas metades do setup são separadas de propósito: quem esqueceu o
  /// `brew install` e quem esqueceu o modelo têm problemas diferentes, e um
  /// "o ditado não está configurado" mandaria os dois pra mesma busca.
  Future<String?> problem() async {
    if (!await hasBinary()) {
      return 'o ditado precisa do whisper.cpp: `brew install whisper-cpp` '
          '(ou `${config.bin}` no PATH)';
    }
    if (!File(config.model).existsSync()) {
      return 'falta o modelo em ${config.model} — ver configurações › ditado';
    }
    return null;
  }

  /// Se o `whisper-cli` existe. Pelo login shell, como todo o resto: o binário
  /// do brew está num PATH que o app não herda -- ver [Sh].
  @visibleForTesting
  Future<bool> hasBinary() async => (await Sh.run('command -v ${Sh.q(config.bin)}')).ok;

  // --- captura --------------------------------------------------------------

  /// Começa a gravar em [wav]. Null quando começou.
  @visibleForTesting
  Future<String?> record(File wav) async {
    if (Platform.isMacOS) {
      try {
        await _mic.invokeMethod<bool>('start', wav.path);
        return null;
      } on PlatformException catch (e) {
        return e.message ?? 'o microfone não abriu';
      } on MissingPluginException {
        // Um hot reload põe o Dart novo por cima do binário nativo velho, e o
        // método ainda não existe do outro lado. Ver [Notifier.chooseWorkspace].
        return 'este build não tem a metade nativa do microfone';
      }
    }
    final program = await _linuxRecorder();
    if (program == null) {
      return 'o ditado precisa do `parecord` (pulseaudio-utils) ou do `arecord` (alsa-utils)';
    }
    // `exec` pra que o pid seja o do gravador, e não o do shell que o subiu:
    // é nele que o sinal de parada precisa cair. Mesmo motivo do [TermSession].
    _linux = await Process.start(Sh.shell, ['-lc', 'exec $program ${Sh.q(wav.path)}']);
    return null;
  }

  /// Fecha o microfone. Null quando fechou.
  @visibleForTesting
  Future<String?> endRecording() async {
    if (Platform.isMacOS) {
      try {
        await _mic.invokeMethod<bool>('stop');
        return null;
      } on PlatformException catch (e) {
        return e.message ?? 'o microfone não fechou';
      } on MissingPluginException {
        return 'este build não tem a metade nativa do microfone';
      }
    }
    final rec = _linux;
    _linux = null;
    if (rec == null) return null;
    // SIGINT e não SIGKILL: o cabeçalho de um wav traz o tamanho do áudio, que
    // só se sabe no fim -- o gravador volta e o reescreve ao sair por bem.
    // Morto de repente, o arquivo fica com um cabeçalho que diz zero.
    Process.killPid(rec.pid, ProcessSignal.sigint);
    await rec.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      Process.killPid(rec.pid, ProcessSignal.sigkill);
      return -1;
    });
    return null;
  }

  Process? _linux;

  /// O gravador que esta máquina tem, com a linha de comando pronta menos o
  /// arquivo. PulseAudio primeiro: é o que está na frente do ALSA em qualquer
  /// desktop moderno, e o `arecord` de uma máquina com Pulse fala com um
  /// dispositivo emulado.
  Future<String?> _linuxRecorder() async {
    if ((await Sh.run('command -v parecord')).ok) {
      return 'parecord --rate=16000 --channels=1 --format=s16le --file-format=wav';
    }
    if ((await Sh.run('command -v arecord')).ok) {
      return 'arecord -q -f S16_LE -r 16000 -c 1 -t wav';
    }
    return null;
  }

  // --- transcrição ------------------------------------------------------------

  /// O whisper.cpp lendo [wav].
  @visibleForTesting
  Future<({String? text, String? problem})> transcribe(File wav) async {
    final r = await Sh.run(command(wav.path));
    if (!r.ok) {
      // A última linha do stderr é onde o whisper diz o que houve; o resto é
      // o dump de sistema que ele imprime antes de tentar.
      final said = r.stderr.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull;
      return (text: null, problem: 'o whisper não transcreveu${said == null ? '' : ': $said'}');
    }
    return (text: clean(r.stdout), problem: null);
  }

  /// A linha de comando, montada à parte pra poder ser lida em teste sem
  /// microfone, sem binário e sem modelo.
  ///
  /// `-nt` tira os carimbos de tempo e `-np` tira o dump de sistema -- que sai
  /// todo em stderr, de modo que o stdout é só o que foi dito. O idioma é fixo
  /// e não `auto` de propósito: numa frase em português com três palavras em
  /// inglês no meio -- que é como se fala de código -- o detector escolhe
  /// inglês e transcreve a frase inteira traduzida.
  ///
  /// O `--prompt` é o que faz esta transcrição servir pra falar de código. Ele
  /// não é uma instrução: é um trecho que o whisper finge ter acabado de
  /// transcrever, e que por isso enviesa o decodificador pro vocabulário que
  /// está nele. Medido nesta mesma frase, sem ele e com ele:
  ///
  ///     Abre uma UASC Trade Outfix Bag 45902 e roda o Flutter Analise…
  ///     Abre uma worktree, hotfix, BUG#45902 e roda o flutter, analise…
  ///
  /// -- inclusive o `#` do id da tarefa, que é como o time escreve.
  String command(String wav) => [
    Sh.q(config.bin),
    '-m ${Sh.q(config.model)}',
    '-f ${Sh.q(wav)}',
    '-l ${Sh.q(config.lang)}',
    if (config.prompt.isNotEmpty) '--prompt ${Sh.q(config.prompt)}',
    '-nt',
    '-np',
  ].join(' ');

  /// O que o whisper escreveu, virando o que se cola num prompt.
  ///
  /// As quebras de linha vão embora porque não são as da fala: o whisper corta
  /// por segmento de áudio, a cada ~30 s ou num silêncio, e colar isso num
  /// prompt de TUI daria uma frase partida em três linhas -- que numa delas
  /// vira envio.
  static String clean(String raw) => raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !_annotation.hasMatch(line))
      .join(' ')
      .trim();

  /// Silêncio tem nome no whisper. Uma linha que é só um par de colchetes ou
  /// parênteses -- `[BLANK_AUDIO]`, `(música ao fundo)` -- é uma anotação dele
  /// sobre o áudio, não algo que alguém disse.
  static final _annotation = RegExp(r'^[\[(][^\])]*[\])][.]?$');

  /// Se [text] é um laço, e não uma frase.
  ///
  /// A segunda defesa contra a alucinação, depois do [peak]: quando o áudio
  /// não tem fala mas tem *som* -- ruído de sala, um ventilador, uma porta --,
  /// o whisper não fica em silêncio, ele trava numa palavra e a repete até
  /// encher o segmento (`pinjate, pinjate, pinjate, pinjate…`).
  ///
  /// A regra é a mesma palavra quatro vezes seguidas, que é coisa que ninguém
  /// dita. Vale pra qualquer laço, não só pros que vêm do `--prompt`.
  @visibleForTesting
  static bool looping(String text) {
    final words = text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}#]+', unicode: true))
      ..removeWhere((w) => w.isEmpty);
    if (words.length < _loop) return false;
    var run = 1;
    for (var i = 1; i < words.length; i++) {
      run = words[i] == words[i - 1] ? run + 1 : 1;
      if (run >= _loop) return true;
    }
    return false;
  }

  static const _loop = 4;
}

/// Em que pé está uma fala.
enum DictationPhase { idle, recording, transcribing }

/// O que o ditado precisa saber, e o usuário escolhe.
class DictationConfig {
  DictationConfig({String? bin, String? model, String? lang, String? prompt, bool? submit})
    : bin = _orElse(bin, defaultBin),
      model = _orElse(model, defaultModel),
      lang = _orElse(lang, defaultLang),
      // O único que aceita vazio: apagar o viés é uma escolha legítima -- é o
      // whisper cru --, enquanto apagar o binário é só um campo em branco.
      prompt = prompt?.trim() ?? defaultPrompt,
      submit = submit ?? false;

  /// O nome no PATH, e não um caminho: o brew instala em `/opt/homebrew/bin`
  /// no Apple Silicon e em `/usr/local/bin` no Intel, e o login shell já sabe
  /// a diferença.
  static const defaultBin = 'whisper-cli';

  /// Ao lado do config, que é onde o app já guarda o que é dele. Fora do
  /// bundle porque um modelo de 570 MB não cabe numa `.app` -- e porque
  /// trocá-lo não pode exigir reinstalar o app.
  static String get defaultModel => '$mxStateDir/models/ggml-large-v3-turbo.bin';

  static const defaultLang = 'pt';

  /// O vocabulário em que se fala com o claude, dado ao whisper como se ele
  /// acabasse de transcrevê-lo. Ver [Dictation.command] pra o que isso muda.
  ///
  /// Genérico de propósito: os termos são os de qualquer repositório, mais a
  /// forma dos ids do tracker. Quem trabalha sempre no mesmo projeto ganha
  /// mais acrescentando os nomes dele aqui -- é editável na tela.
  /// O vocabulário, numa frase -- e a frase é de propósito, apesar do risco.
  ///
  /// Medido nas duas formas, sobre a mesma fala:
  ///
  ///     só a lista de termos:  "Abre uma UOSC Trade Outfix Bag 45902…"
  ///     a frase inteira:       "Abre uma worktree, hotfix, BUG#45902…"
  ///
  /// A abertura é o que faz o viés pegar: o whisper trata o prompt como algo
  /// que ele mesmo acabou de transcrever, e uma lista solta não parece
  /// transcrição de nada. O preço é que, sem fala pra transcrever, ele
  /// *continua a frase* -- foi assim que um painel recebeu `Vocabulário:
  /// pinjate, pinjate, pinjate…`. Por isso silêncio não chega até aqui (ver
  /// [Dictation.peak]) e o que volta ainda passa por [Dictation.looping].
  static const defaultPrompt =
      'Ditado de instruções para o Claude Code. Vocabulário: worktree, branch, '
      'hotfix, feature, commit, rebase, merge, pull request, stash, deploy, '
      'endpoint, build, analyze, lint, TASK#48918, BUG#45902.';

  final String bin;
  final String model;
  final String lang;
  final String prompt;

  /// Mandar sozinho, ou só deixar no prompt.
  ///
  /// Desligado de fábrica, e é a escolha certa pra um padrão: transcrição erra
  /// nome de arquivo e nome de branch, e um prompt enviado errado custa um Esc
  /// mais o retrabalho do claude. Quem confia no próprio microfone liga.
  final bool submit;

  DictationConfig copyWith({
    String? bin,
    String? model,
    String? lang,
    String? prompt,
    bool? submit,
  }) => DictationConfig(
    bin: bin ?? this.bin,
    model: model ?? this.model,
    lang: lang ?? this.lang,
    prompt: prompt ?? this.prompt,
    submit: submit ?? this.submit,
  );

  /// Só o que difere do padrão vai pro disco, pelo mesmo motivo dos atalhos e
  /// da tipografia: um padrão que mude numa versão futura chega em quem já tem
  /// config gravado.
  Map<String, dynamic> toJson() => {
    if (bin != defaultBin) 'bin': bin,
    if (model != defaultModel) 'model': model,
    if (lang != defaultLang) 'lang': lang,
    if (prompt != defaultPrompt) 'prompt': prompt,
    if (submit) 'submit': true,
  };

  static DictationConfig fromJson(Object? json) => json is! Map
      ? DictationConfig()
      : DictationConfig(
          bin: json['bin'] as String?,
          model: json['model'] as String?,
          lang: json['lang'] as String?,
          prompt: json['prompt'] as String?,
          submit: json['submit'] as bool?,
        );

  /// Um campo apagado na tela volta a ser o padrão, em vez de virar um comando
  /// vazio que falha na próxima fala.
  static String _orElse(String? value, String fallback) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? fallback : trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is DictationConfig &&
      other.bin == bin &&
      other.model == model &&
      other.lang == lang &&
      other.prompt == prompt &&
      other.submit == submit;

  @override
  int get hashCode => Object.hash(bin, model, lang, prompt, submit);
}
*/
