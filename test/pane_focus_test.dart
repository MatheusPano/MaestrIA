import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/panes.dart';
import 'package:maestria/ui/terminal_pane.dart';

/// Dois painéis lado a lado, o teclado no da esquerda.
AppStore twoPanes() {
  final store = AppStore();
  final folder = Folder(root: '/repo', name: 'meu-repo');
  store.folders.add(folder);
  for (final name in ['um', 'dois']) {
    store.tabs.add(
      MxTab(
        id: name,
        folder: folder,
        kind: TabKind.shell,
        cwd: '/repo',
        branch: '',
        customLabel: name,
      ),
    );
  }
  store.panes = PaneSplit(PaneAxis.row, [PaneLeaf('um'), PaneLeaf('dois')], [0.5, 0.5]);
  store.focusedPaneId = 'um';
  return store;
}

Future<void> pumpPanes(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1400, 800);
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

void main() {
  group('foco do painel', () {
    // O pty tem reconhecedores de gesto próprios e ganhava a arena: clicar no
    // miolo dava o teclado ao terminal sem o anel sair de onde estava.
    testWidgets('clicar no miolo do terminal acende o anel daquele painel', (tester) async {
      final store = twoPanes();
      await pumpPanes(tester, store);

      final right = tester.getRect(find.byType(TerminalPane).last);
      await tester.tapAt(right.center);
      await tester.pump();

      expect(store.focusedPaneId, 'dois');
      // O toque no pty arma o relógio do duplo clique do xterm; sem deixá-lo
      // vencer o teste acaba com um timer pendente.
      await tester.pump(const Duration(milliseconds: 400));
      store.dispose();
    });

    testWidgets('clicar no header também', (tester) async {
      final store = twoPanes();
      await pumpPanes(tester, store);

      final right = tester.getRect(find.byType(TerminalPane).last);
      await tester.tapAt(Offset(right.center.dx, right.top + 20));
      await tester.pump();

      expect(store.focusedPaneId, 'dois');
      store.dispose();
    });

    // ⇥ puro continua sendo do terminal — é onde ele completa caminho.
    testWidgets('⌃⇥ passa pro próximo painel e ⌃⇧⇥ volta', (tester) async {
      final store = twoPanes();
      await pumpPanes(tester, store);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(store.focusedPaneId, 'dois');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(store.focusedPaneId, 'um');

      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      store.dispose();
    });

    // O anel andava sozinho: o autofocus do xterm só vale no primeiro quadro,
    // então o painel novo acendia e o teclado continuava no antigo.
    testWidgets('o teclado vai junto com o anel', (tester) async {
      final store = twoPanes();
      await pumpPanes(tester, store);

      store.cyclePane(1);
      await tester.pump();

      final focused = tester
          .widgetList<TerminalPane>(find.byType(TerminalPane))
          .where((p) => p.focused)
          .single;
      expect(focused.tab.id, 'dois');
      expect(primaryFocus?.debugLabel, 'terminal');
      store.dispose();
    });
  });
}
