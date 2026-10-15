import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/shortcuts.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/terminal_find.dart';
import 'package:maestria/ui/find_bar.dart';
import 'package:maestria/ui/keys.dart';
import 'package:maestria/ui/panes.dart';
import 'package:xterm/xterm.dart';

/// Um terminal de [cols] colunas com [text] escrito, sem pty por trás.
Terminal written(String text, {int cols = 40}) => Terminal(maxLines: 1000)
  ..resize(cols, 5)
  ..write(text);

MxTab session(AppStore store, String id) {
  final tab = MxTab(
    id: id,
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
    customLabel: id,
  );
  store.tabs.add(tab);
  return tab;
}

/// A grade com o mapa de atalhos em volta, como em `main.dart`: o ⌘F que sai
/// do campo de busca sobe até ele. [outside] é um campo fora da grade, no
/// lugar da busca da lateral.
Future<void> pumpArea(WidgetTester tester, AppStore store, {FocusNode? outside}) =>
    tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Focus(
            canRequestFocus: false,
            onKeyEvent: (_, event) => MxKeys.dispatch(MxKeys.bindings(store, context), event),
            child: Scaffold(
              body: Column(
                children: [
                  if (outside != null) SizedBox(width: 200, child: TextField(focusNode: outside)),
                  SizedBox(width: 900, height: 400, child: PaneArea(store: store)),
                ],
              ),
            ),
          ),
        ),
      ),
    );

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
  await tester.pump();
  await tester.pump();
}

Future<void> cmdF(WidgetTester tester) =>
    press(tester, LogicalKeyboardKey.keyF, holding: [LogicalKeyboardKey.metaLeft]);

/// O texto da busca, com o debounce do campo vencido.
Future<void> type(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 150));
}

void main() {
  group('a busca no buffer', () {
    test('acha cada ocorrência, de cima pra baixo', () {
      final hits = findInTerminal(written('erro aqui\r\nnada\r\noutro erro'), 'erro');
      expect(hits, [
        const TermHit(CellOffset(0, 0), CellOffset(4, 0)),
        const TermHit(CellOffset(6, 2), CellOffset(10, 2)),
      ]);
    });

    test('maiúscula só conta quando a busca tem uma', () {
      final term = written('Erro ERRO erro');
      expect(findInTerminal(term, 'erro'), hasLength(3));
      expect(findInTerminal(term, 'Erro'), [const TermHit(CellOffset(0, 0), CellOffset(4, 0))]);
    });

    // O painel estreito da grade quebra a resposta do Claude no meio da
    // palavra; procurada linha a linha, ela não estaria em lugar nenhum.
    test('acha a palavra que a largura do painel quebrou em duas linhas', () {
      final term = written('0123456789abc', cols: 10);
      expect(term.buffer.lines[1].isWrapped, isTrue);
      expect(findInTerminal(term, '89ab'), [const TermHit(CellOffset(8, 0), CellOffset(2, 1))]);
    });

    test('um caractere largo ocupa duas células e uma letra da busca', () {
      final hits = findInTerminal(written('a你好b'), '好b');
      expect(hits, [const TermHit(CellOffset(3, 0), CellOffset(6, 0))]);
      expect(findInTerminal(written('a你好b'), '你好'), [
        const TermHit(CellOffset(1, 0), CellOffset(5, 0)),
      ]);
    });

    test('pontuação é texto, não expressão regular', () {
      expect(findInTerminal(written('a.b axb'), 'a.b'), hasLength(1));
    });

    test('para no limite e não acha nada numa busca vazia', () {
      final term = written('x x x x x');
      expect(findInTerminal(term, 'x', limit: 3), hasLength(3));
      expect(findInTerminal(term, ''), isEmpty);
    });
  });

  group('os atalhos', () {
    tearDown(() => MxChord.linux = false);

    test('⌘F é do painel e ⌘⇧F da lateral', () {
      MxChord.linux = false;
      expect(MxAction.findInPane.defaults.map((c) => c.label), ['⌘F']);
      expect(MxAction.search.defaults.map((c) => c.label), ['⇧⌘F']);
    });

    // O Ctrl+F sozinho é do readline; o de terminal no Linux tem o shift.
    test('no Linux, o Ctrl+Shift+F dos terminais de lá', () {
      MxChord.linux = true;
      expect(MxAction.findInPane.defaults.map((c) => c.label), ['Ctrl+Shift+F']);
      expect(MxAction.search.defaults.map((c) => c.label), ['Ctrl+Alt+F']);
      for (final a in [MxAction.findInPane, MxAction.search]) {
        expect(a.defaults.every((c) => c.valid), isTrue, reason: a.id);
      }
    });
  });

  group('a barra no painel', () {
    late AppStore store;
    late MxTab tab;

    setUp(() {
      store = AppStore();
      tab = session(store, 'um');
      store.panes = PaneLeaf(tab.id);
      store.focusedPaneId = tab.id;
    });

    tearDown(() => store.dispose());

    Future<void> open(WidgetTester tester) async {
      await pumpArea(tester, store);
      await tester.pump();
      tab.term.terminal.write('primeiro erro\r\nnada aqui\r\nsegundo erro\r\n');
      await tester.pump();
      await cmdF(tester);
    }

    List<TerminalHighlight> marks() => tab.term.controller.highlights;

    testWidgets('⌘F no terminal abre a busca com o teclado nela', (tester) async {
      await open(tester);
      expect(find.byType(FindBar), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('destaca os achados e começa pelo mais recente', (tester) async {
      await open(tester);
      await type(tester, 'erro');
      expect(marks(), hasLength(2));
      expect(find.text('2 de 2'), findsOneWidget);

      // Enter sobe: o que se procura no terminal é algo que já passou.
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.text('1 de 2'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter, holding: [LogicalKeyboardKey.shiftLeft]);
      expect(find.text('2 de 2'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('diz quando não acha nada', (tester) async {
      await open(tester);
      await type(tester, 'inexistente');
      expect(find.text('Nenhum'), findsOneWidget);
      expect(marks(), isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('o que o painel escreve depois entra na contagem', (tester) async {
      await open(tester);
      await type(tester, 'erro');
      tab.term.terminal.write('terceiro erro\r\n');
      await tester.pump(const Duration(milliseconds: 300));
      expect(marks(), hasLength(3));
      // O da vez não pula pro novo: é o que a pessoa estava lendo.
      expect(find.text('2 de 3'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('Esc fecha, apaga os destaques e devolve o teclado ao pty', (tester) async {
      await open(tester);
      await type(tester, 'erro');
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.byType(FindBar), findsNothing);
      expect(marks(), isEmpty);

      final written = <String>[];
      tab.term.terminal.onOutput = written.add;
      await press(tester, LogicalKeyboardKey.enter);
      expect(written, ['\r']);
      await tester.pump(const Duration(milliseconds: 500));
    });

    // Com o foco fora do terminal o ⌘F sobe pro mapa global, que acha o
    // painel em foco pelo [TerminalFind].
    testWidgets('⌘F de fora do terminal abre a busca do painel em foco', (tester) async {
      final outside = FocusNode(debugLabel: 'lateral');
      addTearDown(outside.dispose);
      await pumpArea(tester, store, outside: outside);
      await tester.pump();
      outside.requestFocus();
      await tester.pump();
      await cmdF(tester);
      expect(find.byType(FindBar), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).last).focusNode!.hasFocus, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
    });
  });
}
