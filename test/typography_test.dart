import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/docs.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/theme.dart';
import 'package:maestria/ui/doc_pane.dart';
import 'package:maestria/ui/keys.dart';
import 'package:maestria/ui/settings.dart';
import 'package:maestria/ui/terminal_pane.dart';
import 'package:xterm/xterm.dart';

/// Um painel no único lugar da tela, sem pty: quem mede o corpo do texto é o
/// [TerminalView], e ele não precisa de processo nenhum pra ser medido.
MxTab panel(AppStore store, {TabKind kind = TabKind.claude, MxDoc? doc}) {
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: kind,
    cwd: '/repo',
    branch: '',
    doc: doc,
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;
  return tab;
}

/// A mesma fiação do `main.dart`: a tipografia escutada acima do
/// [MaterialApp] e a store dentro dele. Sem as duas, trocar o corpo mudaria o
/// modelo e nada na tela — que é justamente o que estes testes checam.
Future<void> pumpPane(WidgetTester tester, AppStore store, MxTab tab) => tester.pumpWidget(
  AnimatedBuilder(
    animation: Mx.chrome,
    builder: (context, _) => MaterialApp(
      home: AnimatedBuilder(
        animation: store,
        builder: (context, _) => Scaffold(
          body: SizedBox(
            width: 720,
            height: 320,
            child: tab.isReader
                ? DocPane(store: store, tab: tab)
                : TerminalPane(store: store, tab: tab),
          ),
        ),
      ),
    ),
  ),
);

TerminalStyle styleOf(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).textStyle;

/// Um pump que passa pelo debounce de [AppStore], não só pelo frame.
///
/// Trocar o corpo — como abrir um painel — agenda a escrita do config, e um
/// timer de 400ms ainda pendente reprova o teste de widget antes de o
/// `tearDown` existir. Ver o mesmo tropeço no `reader_test`.
Future<void> settle(WidgetTester tester) => tester.pump(const Duration(milliseconds: 500));

void main() {
  // A tipografia é global como a paleta: um teste que a troca e vai embora
  // deixaria o pty do teste seguinte no corpo errado.
  tearDown(() => Mx.applyType(MxType.standard));

  group('o modelo', () {
    test('o padrão é o pty que sempre existiu', () {
      expect(Mx.mono, 'Hack');
      expect(Mx.terminalFontSize, 13.0);
      expect(Mx.terminalLineHeight, 1.2);
    });

    test('um config editado à mão é contido, não obedecido', () {
      final wild = MxType.fromJson({'size': 400.0, 'line': -3.0});
      expect(wild.size, MxType.maxSize);
      expect(wild.line, MxType.minLine);
    });

    test('uma face que esta máquina não tem cai na que vem no app', () {
      expect(MxType(mono: 'Comic Mono do amigo').mono, 'Hack');
      expect(MxFaces.byFamily('nada disso').family, MxFaces.hack.family);
      expect(MxFaces.installed, contains(MxFaces.hack));
    });

    test('só o que difere do padrão vai pro disco', () {
      expect(MxType.standard.toJson(), isEmpty);
      expect(MxType.standard.copyWith(size: 16).toJson(), {'size': 16.0});
    });

    test('e volta igual', () {
      final chosen = MxType(size: 17, line: 1.45);
      expect(MxType.fromJson(chosen.toJson()), chosen);
    });

    test('a entrelinha não junta lixo de ponto flutuante', () {
      var type = MxType.standard;
      for (var i = 0; i < 3; i++) {
        type = type.copyWith(line: type.line + MxType.lineStep);
      }
      // 1.2 + 0.1 três vezes é 1.5000000000000002 em double; o config e a
      // igualdade querem 1.5.
      expect(type.line, 1.5);
      expect(type.toJson()['line'], 1.5);
    });
  });

  group('o zoom de um painel', () {
    test('é contido pelo que a base deixa', () {
      final big = MxType(size: MxType.maxSize);
      expect(big.clampZoom(4), 0, reason: 'no teto, ⌘+ não tem pra onde ir');
      expect(big.sizeAt(4), MxType.maxSize);

      final small = MxType(size: MxType.minSize);
      expect(small.clampZoom(-4), 0);
      expect(small.sizeAt(2), MxType.minSize + 2);
    });

    test('dez ⌘+ além do limite não são dez ⌘− pra voltar', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);

      for (var i = 0; i < 20; i++) {
        store.zoomFocused(1);
      }
      expect(tab.fontSize, MxType.maxSize);

      store.zoomFocused(-1);
      expect(tab.fontSize, MxType.maxSize - 1, reason: 'um ⌘− volta um ponto, e não onze');
    });

    test('trocar a base leva o painel junto, e mantém a diferença', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);

      store.zoomFocused(2);
      expect(tab.fontSize, 15.0);

      store.setTypography(MxType(size: 10));
      expect(tab.fontSize, 12.0, reason: 'dois pontos acima da base nova');
    });

    test('⌘0 devolve o painel à base', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);

      store.zoomFocused(3);
      store.resetZoomFocused();
      expect(tab.zoom, 0);
      expect(tab.fontSize, MxType.standard.size);
    });

    test('sobrevive ao config, e volta contido pela base de então', () {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      store.zoomFocused(6);
      expect(tab.toJson()['zoom'], 6);

      // A base baixou desde a última vez: o painel salvo não volta fora do teto.
      Mx.applyType(MxType(size: MxType.maxSize - 1));
      expect(Mx.type.clampZoom(tab.toJson()['zoom'] as int), 1);
    });

    test('um painel na base não escreve zoom nenhum', () {
      final store = AppStore();
      addTearDown(store.dispose);
      expect(panel(store).toJson(), isNot(contains('zoom')));
    });
  });

  group('as teclas', () {
    test('⌘= ⌘⇧= ⌘− ⌘0 são combinações que o mapa aceita', () {
      for (final action in [MxAction.zoomIn, MxAction.zoomOut, MxAction.zoomReset]) {
        for (final chord in action.defaults) {
          expect(chord.rejection, isNull, reason: '${action.id}: ${chord.label}');
        }
      }
      expect(MxAction.zoomIn.defaults.map((c) => c.label), containsAll(['⌘=', '⇧⌘=']));
    });

    test('⌘0 não é uma das nove sessões da lateral', () {
      // ⌘1 a ⌘9 são fixos e não passam pelo keymap; ⌘0 tinha que sobrar.
      expect(MxKeys.digits, isNot(contains(LogicalKeyboardKey.digit0)));
      expect(
        MxKeymap().owner(const MxChord(LogicalKeyboardKey.digit0, meta: true)),
        MxAction.zoomReset,
      );
    });

    test('e vão pro disco com nome legível', () {
      expect(MxAction.zoomOut.defaults.single.id, 'meta+-');
      expect(MxChord.parse('meta+-'), MxAction.zoomOut.defaults.single);
    });
  });

  group('na tela', () {
    testWidgets('o pty é desenhado na tipografia escolhida', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      await pumpPane(tester, store, panel(store));
      expect(styleOf(tester).fontSize, 13.0);

      store.setTypography(MxType(size: 18, line: 1.5));
      await settle(tester);

      final style = styleOf(tester);
      expect(style.fontSize, 18.0);
      expect(style.height, 1.5);
    });

    testWidgets('e cada painel no corpo que ele pediu', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(store);
      await pumpPane(tester, store, tab);

      store.zoomFocused(2);
      await settle(tester);

      expect(styleOf(tester).fontSize, 15.0);
    });

    testWidgets('a mesma combinação devolve a mesma instância de estilo', (tester) async {
      // [TerminalStyle] não tem igualdade de valor: o painter do xterm compara
      // por identidade, e uma instância nova por build faria ele remedir a
      // célula e remarcar o layout a cada tique do relógio da lateral.
      final store = AppStore();
      addTearDown(store.dispose);
      await pumpPane(tester, store, panel(store));
      final first = styleOf(tester);

      store.notifyListeners();
      await tester.pump();

      expect(styleOf(tester), same(first));
      expect(Mx.ptyStyle(1), isNot(same(first)));
    });

    testWidgets('a seção de aparência cabe no diálogo', (tester) async {
      // O diálogo tem 800x620 fixos e a lista de faces é longa: um Wrap que
      // não quebrasse, ou um stepper largo demais, estouraria aqui — e um
      // overflow é exceção em teste de widget, não um risco amarelo na tela.
      await tester.binding.setSurfaceSize(const Size(1200, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = AppStore();
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSettings(context, store),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();

      expect(find.text('tipografia do pty'), findsOne);
      expect(find.text('corpo'), findsOne);
      expect(find.text('13px'), findsOne);
      expect(find.text('1.20'), findsOne);
      // A face que vem no app está sempre entre as oferecidas.
      expect(find.text(MxFaces.hack.family), findsOne);

      // A galeria de temas é alta: o bloco existe, mas está abaixo da dobra —
      // e um tap em algo fora da viewport acerta o que estiver no lugar dele.
      final more = find.byTooltip('mais').first;
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.text('14px'), findsOne);
      expect(Mx.type.size, 14.0);
      await settle(tester);
    });

    testWidgets('um leitor soma os mesmos passos à escala do markdown', (tester) async {
      final store = AppStore();
      addTearDown(store.dispose);
      final tab = panel(
        store,
        kind: TabKind.reader,
        doc: MxDoc(source: DocSource.plan, title: 'plano', text: '# oi\n\num plano.'),
      );
      await pumpPane(tester, store, tab);

      double body() => tester
          .widget<MarkdownBody>(find.byType(MarkdownBody))
          .styleSheet!
          .p!
          .fontSize!;
      expect(body(), MxMarkdown.baseSize);

      store.zoomFocused(2);
      await settle(tester);
      expect(body(), MxMarkdown.baseSize + 2);
    });
  });
}
