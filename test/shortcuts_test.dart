import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/keys.dart';
import 'package:maestria/ui/settings.dart';

const _cmdT = MxChord(LogicalKeyboardKey.keyT, meta: true);

/// A tela de configurações dentro de um app de mentira, aberta pelo mesmo
/// [showSettings] que a lateral e o atalho usam.
Future<AppStore> pumpSettings(WidgetTester tester) async {
  final store = AppStore();
  await tester.pumpWidget(
    MaterialApp(
      theme: Mx.theme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showSettings(ctx, store),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return store;
}

/// Desmonta a tela e recolhe o store.
///
/// Trocar um atalho agenda a gravação do config, e um timer desses vivo no fim
/// do teste é um teste que falha — ou, pior, um teste que escreve no
/// ~/.maestria de quem o rodou. Desmontar antes de [AppStore.dispose] é o que
/// cancela a gravação com a árvore ainda inteira.
Future<void> closeWindow(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  store.dispose();
}

/// Uma combinação digitada de verdade: os modificadores descem antes da tecla
/// e sobem depois dela, que é a ordem em que um teclado a produz.
Future<void> press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> holding = const [],
}) async {
  for (final m in holding) {
    await tester.sendKeyDownEvent(m, platform: 'macos');
  }
  await tester.sendKeyDownEvent(key, platform: 'macos');
  await tester.sendKeyUpEvent(key, platform: 'macos');
  for (final m in holding.reversed) {
    await tester.sendKeyUpEvent(m, platform: 'macos');
  }
  await tester.pumpAndSettle();
}

/// A janela reduzida ao que um atalho precisa: o mapa montado do store, e um
/// contexto abaixo do Navigator pra um diálogo poder abrir.
Future<AppStore> pumpKeys(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Mx.theme(),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => CallbackShortcuts(
            bindings: MxKeys.bindings(store, ctx),
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// Um painel na tela e em foco, sem pty atrás dele.
MxTab focusedPanel(AppStore store, {String title = 'permissão do drive'}) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: title,
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

void main() {
  group('combinações', () {
    test('o que se lê na tela e o que vai pro disco são a mesma tecla', () {
      expect(_cmdT.label, '⌘T');
      expect(_cmdT.id, 'meta+t');
      expect(MxChord.parse('meta+t'), _cmdT);

      // Ida e volta em tudo que o mapa traz de fábrica: um atalho que não
      // sobrevive ao próprio config é um atalho que some no próximo boot.
      for (final action in MxAction.values) {
        for (final chord in action.defaults) {
          expect(MxChord.parse(chord.id), chord, reason: chord.label);
        }
      }
    });

    test('as setas e o tab se escrevem como teclas, não como palavras', () {
      const chord = MxChord(LogicalKeyboardKey.arrowRight, meta: true, alt: true);
      expect(chord.label, '⌥⌘→');
      expect(chord.id, 'alt+meta+right');
      expect(const MxChord(LogicalKeyboardKey.tab, control: true).label, '⌃⇥');
    });

    test('sem modificador a tecla sumiria do terminal', () {
      expect(const MxChord(LogicalKeyboardKey.keyG).rejection, isNotNull);
      // Um F-key não digita nada, então não tem o que sumir.
      expect(const MxChord(LogicalKeyboardKey.f5).rejection, isNull);
    });

    test('⌃ mais letra é código de controle, e é do processo', () {
      expect(const MxChord(LogicalKeyboardKey.keyC, control: true).rejection, isNotNull);
      // ⌃⇥ não: a keytab do xterm não faz nada de especial com ele.
      expect(const MxChord(LogicalKeyboardKey.tab, control: true).rejection, isNull);
    });

    test('o que o macOS resolve antes da janela é recusado na cara', () {
      // Recusar aqui é o ponto: aceitar produziria uma tecla que nunca chega,
      // e isso não falha na hora, falha meses depois.
      for (final reserved in MxChord.reserved.keys) {
        expect(reserved.rejection, isNotNull, reason: reserved.label);
      }
      expect(const MxChord(LogicalKeyboardKey.keyQ, meta: true).rejection, contains('⌘Q'));
    });

    test('um id que esta versão não conhece é descartado, não explode', () {
      expect(MxChord.parse('hyper+t'), isNull);
      expect(MxChord.parse('meta+teclamágica'), isNull);
      expect(MxChord.parse(''), isNull);
      expect(MxChord.parse(null), isNull);
    });
  });

  group('o mapa de fábrica', () {
    test('nenhuma tecla tem dois donos', () {
      final all = [for (final a in MxAction.values) ...a.defaults];
      expect(all.toSet().length, all.length);
    });

    test('e nenhum padrão é uma combinação que a janela nunca veria', () {
      for (final action in MxAction.values) {
        expect(action.defaults, isNotEmpty, reason: action.label);
        for (final chord in action.defaults) {
          expect(chord.rejection, isNull, reason: '${action.label}: ${chord.label}');
        }
      }
    });

    test('os ids do config não colidem', () {
      final ids = MxAction.values.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('mapa', () {
    test('dar uma tecla a outra ação tira de quem a tinha', () {
      final map = MxKeymap();
      final stolen = map.bind(MxAction.newShell, _cmdT);

      expect(stolen, MxAction.newClaude);
      expect(map[MxAction.newClaude], isNot(contains(_cmdT)));
      expect(map[MxAction.newShell], contains(_cmdT));
      expect(map.owner(_cmdT), MxAction.newShell);
    });

    test('trocar troca; sem dizer o que substituir, soma', () {
      final map = MxKeymap();
      const cmdJ = MxChord(LogicalKeyboardKey.keyJ, meta: true);

      map.bind(MxAction.newClaude, cmdJ, replacing: _cmdT);
      expect(map[MxAction.newClaude], [cmdJ]);

      map.bind(MxAction.newClaude, _cmdT);
      expect(map[MxAction.newClaude], [cmdJ, _cmdT]);
    });

    test('voltar ao padrão devolve a tecla que outra ação tinha levado', () {
      final map = MxKeymap();
      map.bind(MxAction.newShell, _cmdT);
      map.resetAction(MxAction.newClaude);

      expect(map[MxAction.newClaude], MxAction.newClaude.defaults);
      expect(map[MxAction.newShell], isNot(contains(_cmdT)));
      expect(map.owner(_cmdT), MxAction.newClaude);
    });

    test('só o que difere do padrão é gravado', () {
      final map = MxKeymap();
      expect(map.toJson(), isEmpty);

      map.bind(MxAction.refreshGit, const MxChord(LogicalKeyboardKey.f5));
      expect(map.toJson().keys, ['refresh']);
      expect(map.toJson()['refresh'], ['meta+r', 'f5']);
    });

    test('e o que foi gravado volta como estava', () {
      final map = MxKeymap()..bind(MxAction.newShell, _cmdT, replacing: null);
      final restored = MxKeymap()..load(map.toJson());

      expect(restored[MxAction.newShell], map[MxAction.newShell]);
      expect(restored[MxAction.newClaude], map[MxAction.newClaude]);
      expect(restored.allDefault, isFalse);
    });

    test('um config editado à mão não deixa duas ações na mesma tecla', () {
      final map = MxKeymap()
        ..load({
          'claude': ['meta+g'],
          'shell': ['meta+g'],
        });

      expect(map[MxAction.newClaude], [const MxChord(LogicalKeyboardKey.keyG, meta: true)]);
      expect(map[MxAction.newShell], isEmpty);
    });

    test('uma combinação impossível no arquivo é jogada fora sozinha', () {
      // O resto da linha continua valendo: um config estragado não pode
      // custar os atalhos que estavam certos nele.
      final map = MxKeymap()
        ..load({
          'claude': ['meta+q', 'g', 'meta+alt+g'],
        });

      expect(map[MxAction.newClaude], [
        const MxChord(LogicalKeyboardKey.keyG, meta: true, alt: true),
      ]);
    });

    test('restaurar tudo volta ao que veio de fábrica', () {
      final map = MxKeymap()
        ..bind(MxAction.newShell, _cmdT)
        ..unbind(MxAction.refreshGit, MxAction.refreshGit.defaults.first);
      expect(map.allDefault, isFalse);

      map.reset();
      expect(map.allDefault, isTrue);
      expect(map.toJson(), isEmpty);
    });
  });

  group('renomear pelo teclado', () {
    testWidgets('⌘E pergunta o nome do painel em foco', (tester) async {
      final store = await pumpKeys(tester, AppStore());
      final tab = focusedPanel(store);

      await press(tester, LogicalKeyboardKey.keyE, holding: [LogicalKeyboardKey.metaLeft]);
      expect(find.text('renomear painel'), findsOneWidget);
      // Já com o nome de agora dentro: renomear quase sempre é corrigir o que
      // está escrito, não escrever de novo do zero.
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text, tab.title);

      await tester.enterText(find.byType(TextField), 'permissão do google');
      await tester.tap(find.text('ok'));
      await tester.pumpAndSettle();

      expect(tab.title, 'permissão do google');
      await closeWindow(tester, store);
    });

    testWidgets('e sem painel nenhum em foco, não abre diálogo vazio', (tester) async {
      final store = await pumpKeys(tester, AppStore());

      await press(tester, LogicalKeyboardKey.keyE, holding: [LogicalKeyboardKey.metaLeft]);

      expect(find.text('renomear painel'), findsNothing);
      expect(store.banner, contains('renomear'));
      await closeWindow(tester, store);
    });
  });

  group('a tela de configurações', () {
    testWidgets('abre no tema, e o tema é a galeria que era um diálogo', (tester) async {
      final store = await pumpSettings(tester);

      expect(find.text('aparência'), findsOneWidget);
      expect(find.text(MxThemes.nord.label), findsOneWidget);

      await closeWindow(tester, store);
    });

    testWidgets('trocar um atalho é clicar na tecla e digitar a nova', (tester) async {
      final store = await pumpSettings(tester);

      await tester.tap(find.text('atalhos'));
      await tester.pumpAndSettle();
      expect(find.text('⌘T'), findsOneWidget);

      await tester.tap(find.text('⌘T'));
      await tester.pumpAndSettle();
      expect(find.textContaining('pressione a combinação'), findsOneWidget);

      await press(
        tester,
        LogicalKeyboardKey.keyG,
        holding: [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.shiftLeft],
      );

      expect(store.keymap[MxAction.newClaude], [
        const MxChord(LogicalKeyboardKey.keyG, meta: true, shift: true),
      ]);
      // ⇧⌘G e não ⌘⇧G: a ordem é a que o macOS imprime, ⌃⌥⇧⌘.
      expect(find.text('⇧⌘G'), findsOneWidget);
      expect(find.text('⌘T'), findsNothing);

      await closeWindow(tester, store);
    });

    testWidgets('uma tecla que não pode diz por que, e não é gravada', (tester) async {
      final store = await pumpSettings(tester);

      await tester.tap(find.text('atalhos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('⌘T'));
      await tester.pumpAndSettle();

      // Sem modificador nenhum: seria uma letra que some do terminal.
      await press(tester, LogicalKeyboardKey.keyG);

      expect(store.keymap[MxAction.newClaude], [_cmdT]);
      expect(find.textContaining('sem modificador'), findsOneWidget);
      // Continua gravando: a tecla recusada não desiste da troca por você.
      expect(find.textContaining('pressione a combinação'), findsOneWidget);

      await closeWindow(tester, store);
    });

    testWidgets('⎋ desiste da gravação sem mexer no mapa', (tester) async {
      final store = await pumpSettings(tester);

      await tester.tap(find.text('atalhos'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('⌘T'));
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.escape);

      expect(store.keymap[MxAction.newClaude], [_cmdT]);
      expect(find.text('⌘T'), findsOneWidget);
      expect(find.textContaining('pressione a combinação'), findsNothing);
      // E o diálogo fica de pé: o ⎋ foi da gravação, não da tela.
      expect(find.byType(Dialog), findsOneWidget);

      await closeWindow(tester, store);
    });
  });
}
