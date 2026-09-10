// --- ditado (vocalização) — fora desta versão ---------------------------------
//
// Ver o cabeçalho de `lib/services/dictation.dart`. A suíte do ditado fica
// aqui inteira, comentada, pra voltar junto com a feature.
//
// O `main` vazio é o que impede a suíte de falhar ao carregar um arquivo
// `_test.dart` sem ele — não é um teste que passa, é um arquivo sem testes.
void main() {}

/*
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/dictation.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/pty.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/settings.dart';
import 'package:maestria/ui/terminal_pane.dart';

/// Um ditado sem microfone e sem whisper.
///
/// As duas pontas de IO são o que um teste não alcança -- não há entrada de
/// áudio numa suíte, e o `whisper-cli` não está na máquina que roda a CI. O
/// miolo é tudo que sobra, e é onde estão as decisões: qual painel recebe, o
/// que acontece com uma fala vazia, e se o texto é colado ou enviado.
class FakeDictation extends Dictation {
  FakeDictation({
    this.heard = 'abre a worktree do BUG#45902',
    this.bytes = 64000,
    this.silent = false,
  });

  /// O que o whisper teria escrito.
  String heard;

  /// O tamanho do wav que a gravação deixou. O padrão são dois segundos de
  /// PCM 16 kHz mono; baixá-lo é como se testa o piso de [Dictation.end].
  int bytes;

  /// Uma entrada morta: grava, e o que grava é zero. Ver [Dictation.peak].
  bool silent;

  bool recording = false;

  /// Setup em dia: o que falta pra ditar tem teste próprio, abaixo.
  @override
  Future<String?> problem() async => null;

  @override
  Future<String?> record(File wav) async {
    recording = true;
    wav.writeAsBytesSync(silent ? silence(bytes) : speech(bytes));
    return null;
  }

  @override
  Future<String?> endRecording() async {
    recording = false;
    return null;
  }

  @override
  Future<({String? text, String? problem})> transcribe(File wav) async =>
      (text: Dictation.clean(heard), problem: null);
}

/// Um wav do nosso formato -- 44 bytes de cabeçalho e PCM 16 bits -- em que
/// não há som nenhum. É o que um jack com fone sem microfone entrega.
List<int> silence(int bytes) => List.filled(44 + bytes, 0);

/// O mesmo, com amostras que se ouvem. O valor foi escolhido na ordem de
/// grandeza do pico medido numa fala de verdade (~24900 de 32767).
List<int> speech(int bytes) => [
  ...List.filled(44, 0),
  for (var i = 0; i < bytes ~/ 2; i++) ...[0x74, 0x61],
];

/// Tudo que o painel escreveria no pty.
List<String> watch(TermSession session) {
  final written = <String>[];
  session.terminal.onOutput = written.add;
  return written;
}

(AppStore, MxTab) storeWithPanel({FakeDictation? mic}) {
  final store = AppStore(dictation: mic ?? FakeDictation());
  final folder = Folder(root: '/repo', name: 'meu-repo');
  final tab = MxTab(
    id: 'tab1',
    folder: folder,
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: 'sessão',
  );
  store.folders.add(folder);
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return (store, tab);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('o que o whisper escreveu, virando prompt', () {
    test('as quebras de segmento viram uma frase só', () {
      // O whisper corta por segmento de áudio, não por frase. Colado com as
      // quebras num prompt de TUI, o primeiro \n já seria um envio.
      expect(
        Dictation.clean(' abre a worktree\ndo BUG#45902\n e roda os testes '),
        'abre a worktree do BUG#45902 e roda os testes',
      );
    });

    test('silêncio tem nome, e o nome não é texto', () {
      expect(Dictation.clean('[BLANK_AUDIO]'), isEmpty);
      expect(Dictation.clean('(música ao fundo)\nroda o analyze'), 'roda o analyze');
    });

    test('mas um parêntese no meio de uma frase é a frase', () {
      const dito = 'usa o hotfix (o da branch velha) pra comparar';
      expect(Dictation.clean(dito), dito);
    });

    test('nada dito é string vazia, não um espaço', () {
      expect(Dictation.clean('\n  \n'), isEmpty);
    });
  });

  group('o laço de alucinação', () {
    test('a mesma palavra quatro vezes seguidas não é ninguém ditando', () {
      // O que o painel recebeu de verdade na primeira vez que isto rodou.
      expect(
        Dictation.looping('Vocabulário: pinjate, pinjate, pinjate, pinjate, pinjate.'),
        isTrue,
      );
    });

    test('mas uma repetição curta é ênfase, e é fala', () {
      expect(Dictation.looping('não, não, não é isso'), isFalse);
      expect(Dictation.looping('roda o analyze'), isFalse);
    });

    test('e uma frase que só repete o assunto continua passando', () {
      expect(
        Dictation.looping('a branch nova sai da branch main, não da branch velha'),
        isFalse,
      );
    });
  });

  group('o medidor de silêncio', () {
    File wavWith(List<int> bytes) {
      final f = File('${Directory.systemTemp.path}/maestria-peak-teste.wav')
        ..writeAsBytesSync(bytes);
      addTearDown(f.deleteSync);
      return f;
    }

    test('uma entrada morta grava zero, e zero é zero', () {
      expect(Dictation.peak(wavWith(silence(64000))), 0);
    });

    test('fala se ouve, e por uma margem que não é de sorte', () {
      // Medido: uma fala de verdade a 16 kHz bate em ~24900 de 32767, e o
      // limiar está em 128 -- duas ordens de grandeza de folga.
      expect(Dictation.peak(wavWith(speech(64000))), greaterThan(20000));
    });

    test('um arquivo que é só cabeçalho não estoura', () {
      expect(Dictation.peak(wavWith(List.filled(44, 0))), 0);
    });
  });

  group('a linha de comando do whisper', () {
    test('leva o modelo, o idioma e o silêncio dos carimbos', () {
      final command = Dictation(
        config: DictationConfig(bin: 'whisper-cli', model: '/m/turbo.bin', lang: 'pt'),
      ).command('/tmp/fala.wav');

      expect(command, contains("-m '/m/turbo.bin'"));
      expect(command, contains("-f '/tmp/fala.wav'"));
      expect(command, contains("-l 'pt'"));
      // Sem os dois, o stdout vem com carimbo de tempo e com o dump de
      // sistema que o whisper imprime antes de começar.
      expect(command, contains('-nt'));
      expect(command, contains('-np'));
    });

    test('o vocabulário entra como --prompt, que é o que salva os termos', () {
      // Medido contra o whisper de verdade nesta mesma frase: sem o prompt,
      // "worktree" e "BUG#45902" saem como "UASC Trade" e "Bag 45902".
      final command = Dictation(config: DictationConfig()).command('/tmp/f.wav');
      expect(command, contains('--prompt'));
      expect(command, contains('worktree'));
    });

    test('vocabulário em branco é o whisper cru, sem o flag', () {
      final command = Dictation(
        config: DictationConfig(prompt: ''),
      ).command('/tmp/f.wav');
      expect(command, isNot(contains('--prompt')));
    });

    test('um caminho com espaço continua sendo um caminho só', () {
      final command = Dictation(
        config: DictationConfig(model: '/Users/eu/Meus Modelos/turbo.bin'),
      ).command('/tmp/fala.wav');

      expect(command, contains(r"-m '/Users/eu/Meus Modelos/turbo.bin'"));
    });
  });

  group('o que falta pra ditar', () {
    test('sem o binário, a resposta é o brew — não o modelo', () async {
      final mic = _SemBinario();
      expect(await mic.problem(), contains('brew install whisper-cpp'));
    });

    test('com o binário e sem o modelo, a resposta é o modelo', () async {
      final mic = _ComBinario(DictationConfig(model: '/nao/existe/turbo.bin'));
      final problem = await mic.problem();
      expect(problem, contains('/nao/existe/turbo.bin'));
      expect(problem, isNot(contains('brew')));
    });

    test('com os dois no lugar, não falta nada', () async {
      final model = File('${Directory.systemTemp.path}/maestria-modelo-de-teste.bin')
        ..writeAsStringSync('não é um modelo, mas existe');
      addTearDown(model.deleteSync);

      final mic = _ComBinario(DictationConfig(model: model.path));
      expect(await mic.problem(), isNull);
    });
  });

  group('o config', () {
    test('só o que difere do padrão vai pro disco', () {
      expect(DictationConfig().toJson(), isEmpty);
      expect(DictationConfig(lang: 'en').toJson(), {'lang': 'en'});
    });

    test('sobrevive à ida e volta', () {
      final config = DictationConfig(
        bin: '/opt/whisper',
        lang: 'en',
        prompt: 'worktree, rebase, squash',
        submit: true,
      );
      expect(DictationConfig.fromJson(config.toJson()), config);
    });

    test('um campo apagado na tela volta a ser o padrão', () {
      // Guardar o vazio daria um comando sem programa, que só falharia na
      // próxima fala -- longe da tela onde ele foi apagado.
      expect(DictationConfig(bin: '   ').bin, DictationConfig.defaultBin);
      expect(DictationConfig(lang: '').lang, DictationConfig.defaultLang);
    });

    test('menos o vocabulário, onde apagar é uma escolha e é guardada', () {
      expect(DictationConfig(prompt: '').prompt, isEmpty);
      expect(DictationConfig(prompt: '').toJson(), {'prompt': ''});
    });
  });

  group('ditar num painel', () {
    test('o primeiro toque abre o microfone e o segundo cola o que foi dito', () async {
      final mic = FakeDictation(heard: 'roda o analyze');
      final (store, tab) = storeWithPanel(mic: mic);
      final written = watch(tab.term);

      await store.toggleDictation();
      expect(mic.recording, isTrue);
      expect(store.dictation.phaseOf(tab.id), DictationPhase.recording);
      expect(written, isEmpty);

      await store.toggleDictation();
      expect(mic.recording, isFalse);
      expect(store.dictation.phaseOf(tab.id), DictationPhase.idle);
      expect(written, ['roda o analyze']);
      store.dispose();
    });

    test('colado e não enviado: nenhum \\r sai junto', () async {
      final (store, tab) = storeWithPanel();
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      // O que transcrição erra é nome de arquivo e nome de branch, e um prompt
      // enviado errado custa um Esc mais o retrabalho do claude.
      expect(written.join(), isNot(contains('\r')));
      store.dispose();
    });

    test('com "enviar sozinho" ligado, o enter vai junto', () async {
      final (store, tab) = storeWithPanel();
      store.setDictation(store.dictation.config.copyWith(submit: true));
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      expect(written.join(), contains('\r'));
      store.dispose();
    });

    test('o texto vai pro painel em que se começou a falar, não pro em foco', () async {
      final (store, falando) = storeWithPanel();
      final outro = MxTab(
        id: 'tab2',
        folder: falando.folder,
        kind: TabKind.claude,
        cwd: '/repo',
        branch: '',
      );
      store.tabs.add(outro);
      final naFala = watch(falando.term);
      final noOutro = watch(outro.term);

      await store.toggleDictation();
      // Trinta segundos de fala dão tempo de clicar em outro painel.
      store.focusedPaneId = outro.id;
      await store.toggleDictation();

      expect(naFala, isNotEmpty);
      expect(noOutro, isEmpty);
      store.dispose();
    });

    test('meio segundo de áudio não é uma frase, e nada é colado', () async {
      // O segundo toque chegando junto com o primeiro. O whisper transcreve
      // isso como uma alucinação curta, que é pior do que nada.
      final (store, tab) = storeWithPanel(mic: FakeDictation(bytes: 400));
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      expect(written, isEmpty);
      expect(store.banner, contains('não deu tempo'));
      store.dispose();
    });

    test('silêncio nunca chega ao whisper, que alucinaria em cima dele', () async {
      // O primeiro ditado real desta feature: fone sem microfone no jack, o
      // macOS elegeu o "Microfone Externo" morto, e o whisper devolveu
      // "Vocabulário: pinjate, pinjate, pinjate…" -- ele continuando o
      // `--prompt`. Parecia que tinha funcionado, que é o pior desfecho.
      final mic = FakeDictation(silent: true);
      final (store, tab) = storeWithPanel(mic: mic);
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      expect(written, isEmpty);
      expect(store.banner, contains('não captou som'));
      // E a dica de onde olhar, que é a única coisa que resolve.
      expect(store.banner, contains('Entrada'));
      store.dispose();
    });

    test('ruído que virou laço é recusado, e o banner mostra o que veio', () async {
      final mic = FakeDictation(heard: 'pinjate, pinjate, pinjate, pinjate, pinjate');
      final (store, tab) = storeWithPanel(mic: mic);
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      expect(written, isEmpty);
      expect(store.banner, contains('ruído, não fala'));
      store.dispose();
    });

    test('uma fala que só deu silêncio diz isso, e não cola vazio', () async {
      final (store, tab) = storeWithPanel(mic: FakeDictation(heard: '[BLANK_AUDIO]'));
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.toggleDictation();

      expect(written, isEmpty);
      expect(store.banner, contains('não entendi nada'));
      store.dispose();
    });

    test('sem painel em foco não há onde ditar, e o microfone não abre', () async {
      final mic = FakeDictation();
      final store = AppStore(dictation: mic);

      await store.toggleDictation();

      expect(mic.recording, isFalse);
      expect(store.banner, contains('painel'));
      store.dispose();
    });

    test('o áudio não fica no disco depois de virar texto', () async {
      final (store, _) = storeWithPanel();

      await store.toggleDictation();
      expect(Dictation.scratch.existsSync(), isTrue);
      await store.toggleDictation();

      expect(Dictation.scratch.existsSync(), isFalse);
      store.dispose();
    });

    test('desistir joga o áudio fora sem transcrever nada', () async {
      final (store, tab) = storeWithPanel();
      final written = watch(tab.term);

      await store.toggleDictation();
      await store.dictation.cancel();

      expect(written, isEmpty);
      expect(Dictation.scratch.existsSync(), isFalse);
      expect(store.dictation.busy, isFalse);
      store.dispose();
    });
  });

  group('a tela do ditado', () {
    testWidgets('com o setup pronto, não ensina setup nenhum', (tester) async {
      final store = AppStore(dictation: FakeDictation());
      await pumpSettings(tester, store);

      expect(find.textContaining('tudo no lugar'), findsOneWidget);
      expect(find.textContaining('brew install'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
    });

    testWidgets('faltando o whisper, os comandos aparecem prontos pra copiar', (tester) async {
      final store = AppStore(dictation: _SemBinario());
      await pumpSettings(tester, store);

      expect(find.textContaining('brew install whisper-cpp'), findsWidgets);
      // O curl é montado em cima do caminho configurado -- copiar um comando
      // que baixa pra outro lugar seria pior do que não oferecer comando.
      expect(
        find.textContaining(DictationConfig.defaultModel),
        findsWidgets,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
    });
  });

  group('o cabeçalho do painel', () {
    testWidgets('diz que está ouvindo, e some quando para', (tester) async {
      final (store, tab) = storeWithPanel();
      await pumpPane(tester, store, tab);
      expect(find.text('ouvindo…'), findsNothing);

      await store.toggleDictation();
      // `pump` e não `pumpAndSettle`: o pulso do microfone não termina nunca,
      // que é justamente o ponto dele.
      await tester.pump();
      expect(find.text('ouvindo…'), findsOneWidget);

      await store.toggleDictation();
      await tester.pump();
      expect(find.text('ouvindo…'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    });
  });

  group('o atalho', () {
    test('⌘⇧D é o padrão, e é de quem se espera', () {
      final keymap = MxKeymap();
      final chord = MxAction.dictate.defaults.single;

      expect(chord.label, '⇧⌘D');
      expect(keymap.owner(chord), MxAction.dictate);
    });

    test('não briga com nenhum outro', () {
      // O mapa de fábrica inteiro tem que ser um por tecla; ver [MxKeymap].
      final keymap = MxKeymap();
      final all = [for (final a in MxAction.values) ...keymap[a]];
      expect(all.toSet().length, all.length);
    });
  });
}

/// A seção do ditado, aberta pelo mesmo [showSettings] que o atalho usa.
Future<void> pumpSettings(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Mx.theme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showSettings(ctx, store, section: MxSection.dictation),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
}

/// Um painel na tela, do tamanho de um painel de verdade.
///
/// Debaixo de um [AnimatedBuilder] no store como em `main.dart`: é ele que faz
/// o cabeçalho se redesenhar quando o microfone abre, e um painel pumpado solto
/// mostraria pra sempre o estado do primeiro quadro.
Future<void> pumpPane(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
  MaterialApp(
    theme: Mx.theme(),
    home: AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        body: SizedBox(width: 720, height: 320, child: TerminalPane(store: store, tab: tab)),
      ),
    ),
  ),
);

/// Uma máquina sem `whisper-cli` no PATH.
class _SemBinario extends Dictation {
  @override
  Future<bool> hasBinary() async => false;
}

/// Uma máquina com o binário; o que falta -- ou não -- é o modelo.
class _ComBinario extends Dictation {
  _ComBinario(DictationConfig config) : super(config: config);

  @override
  Future<bool> hasBinary() async => true;
}
*/
