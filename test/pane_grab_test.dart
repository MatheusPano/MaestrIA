import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/panes.dart';
import 'package:maestria/ui/terminal_pane.dart';

/// Uma pasta com um painel por nome, todos lado a lado na tela.
AppStore storeWith(List<String> names) {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo')
    ..isRepo = true
    ..branch = 'master';
  store.folders.add(folder);
  for (final name in names) {
    store.tabs.add(
      MxTab(
        id: name,
        folder: folder,
        kind: TabKind.claude,
        cwd: '/repo',
        branch: '',
        customLabel: name,
      ),
    );
  }
  store.panes = names.length == 1
      ? PaneLeaf(names.first)
      : PaneSplit(
          PaneAxis.row,
          [for (final n in names) PaneLeaf(n)],
          [for (final _ in names) 1 / names.length],
        );
  store.focusedPaneId = names.first;
  return store;
}

Future<void> pumpArea(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1800, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) => PaneArea(store: store),
        ),
      ),
    ),
  );
}

Rect paneRect(WidgetTester tester, String id) =>
    tester.getRect(find.byWidgetPredicate((w) => w is TerminalPane && w.tab.id == id));

/// Pega o painel [from] pelo cabeçalho -- perto do nome, e não no centro, onde
/// a faixa tem botões -- e solta no ponto pedido do painel [onto], dado em
/// fração dele: (0.05, 0.5) é a borda esquerda.
Future<void> dragHeader(
  WidgetTester tester,
  String from, {
  required String onto,
  required double x,
  required double y,
}) async {
  final start = paneRect(tester, from).topLeft + const Offset(60, 20);
  final pane = paneRect(tester, onto);
  final target = Offset(pane.left + pane.width * x, pane.top + pane.height * y);
  final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump();
  // Em dois passos: o primeiro passa do limiar que separa arraste de clique.
  await gesture.moveBy(const Offset(30, 0));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  // Nunca pumpAndSettle: a marca do claude pulsa pra sempre.
  await tester.pump();
}

void main() {
  group('arrastar um painel pelo cabeçalho', () {
    testWidgets('solto na borda esquerda de outro, vai pra antes dele', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpArea(tester, store);

      await dragHeader(tester, 'tres', onto: 'um', x: 0.05, y: 0.5);

      expect(Panes.order(store.panes), ['tres', 'um', 'dois']);
      expect(store.focusedPaneId, 'tres');
      store.dispose();
    });

    testWidgets('solto embaixo de outro, os dois viram uma coluna', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpArea(tester, store);

      await dragHeader(tester, 'um', onto: 'dois', x: 0.5, y: 0.95);

      final root = store.panes as PaneSplit;
      expect(Panes.order(root), ['dois', 'um', 'tres']);
      expect(root.children.length, 2);
      expect((root.children.first as PaneSplit).axis, PaneAxis.column);
      store.dispose();
    });

    testWidgets('solto no meio de outro, toma o lugar dele sem fechar a sessão', (tester) async {
      final store = storeWith(['um', 'dois']);
      await pumpArea(tester, store);

      await dragHeader(tester, 'um', onto: 'dois', x: 0.5, y: 0.5);

      expect(Panes.order(store.panes), ['um']);
      expect(store.tabs.map((t) => t.id), containsAll(['um', 'dois']));
      store.dispose();
    });

    testWidgets('solto em cima de si mesmo, nada muda e nenhuma marca acende', (tester) async {
      final store = storeWith(['um', 'dois']);
      await pumpArea(tester, store);

      final start = paneRect(tester, 'um').topLeft + const Offset(60, 20);
      final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(40, 200));
      await tester.pump();
      expect(find.text('Dividir'), findsNothing);
      expect(find.text('Trocar'), findsNothing);
      await gesture.up();
      await tester.pump();

      expect(Panes.order(store.panes), ['um', 'dois']);
      store.dispose();
    });

    testWidgets('um clique parado num botão da faixa continua sendo do botão', (tester) async {
      final store = storeWith(['um', 'dois']);
      await pumpArea(tester, store);

      await tester.tap(find.byIcon(Icons.push_pin_outlined).first);
      await tester.pump();

      expect(store.isPinned(store.tabById('um')!), isTrue);
      expect(Panes.order(store.panes), ['um', 'dois']);
      store.dispose();
    });

    testWidgets('com um painel só, o cabeçalho não se oferece', (tester) async {
      final store = storeWith(['um']);
      await pumpArea(tester, store);

      expect(find.byType(Draggable<MxTab>), findsNothing);
      store.dispose();
    });
  });
}
