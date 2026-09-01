import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/ui/panes.dart';
import 'package:maestria/ui/sidebar.dart';
import 'package:maestria/ui/terminal_pane.dart';

/// Uma pasta com um painel por nome, o primeiro deles na tela.
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
  store.panes = PaneLeaf(names.first);
  store.focusedPaneId = names.first;
  return store;
}

/// A janela inteira: a lateral de onde se pega, a região onde se solta. A
/// largura da lateral é a do reorder_test, pela mesma razão -- as fichas do
/// "+ terminal" não cabem em menos.
Future<void> pumpWindow(WidgetTester tester, AppStore store, {double width = 2200}) async {
  // A tela de teste é 800x600 por padrão: estreita demais pra uma lateral e
  // uma grade ao lado dela, e um painel de 70px não se divide em nada.
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Row(
            children: [
              SizedBox(width: 660, child: Sidebar(store: store)),
              Expanded(child: PaneArea(store: store)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Pega a linha [row] na lateral e solta no ponto pedido do painel na tela.
///
/// O ponto é dado em fração do painel: (0.95, 0.5) é a borda direita dele.
Future<void> dropOnPane(
  WidgetTester tester,
  String row, {
  required double x,
  required double y,
}) async {
  final pane = tester.getRect(find.byType(TerminalPane).first);
  final target = Offset(pane.left + pane.width * x, pane.top + pane.height * y);
  // A linha é pega fora do centro de propósito: é o que quebrava a conta do
  // lado antes -- o offset que o DragTarget entrega sai daqui.
  final start = tester.getTopLeft(find.text(row)) + const Offset(4, 4);
  final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump();
  await gesture.up();
  // Nunca pumpAndSettle: a marca do claude pulsa pra sempre.
  await tester.pump();
}

void main() {
  group('soltar na região principal', () {
    testWidgets('pela borda direita, a tela vira dois painéis', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store);

      await dropOnPane(tester, 'dois', x: 0.95, y: 0.5);

      expect(Panes.order(store.panes), ['um', 'dois']);
      expect(find.byType(TerminalPane), findsNWidgets(2));
      store.dispose();
    });

    // O que a faixa de borda com teto em pixels errava: num painel largo,
    // soltar um palmo depois do meio ainda dizia "trocar".
    testWidgets('um palmo à direita do meio já divide', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store);

      await dropOnPane(tester, 'dois', x: 0.68, y: 0.5);

      expect(Panes.order(store.panes), ['um', 'dois']);
      expect((store.panes as PaneSplit).axis, PaneAxis.row);
      store.dispose();
    });

    testWidgets('pela borda de baixo, um em cima do outro', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store);

      await dropOnPane(tester, 'dois', x: 0.5, y: 0.95);

      expect(Panes.order(store.panes), ['um', 'dois']);
      final split = store.panes as PaneSplit;
      expect(split.axis, PaneAxis.column);
      store.dispose();
    });

    testWidgets('pelo meio, toma o lugar do painel em vez de dividir', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store);

      await dropOnPane(tester, 'dois', x: 0.5, y: 0.5);

      expect(Panes.order(store.panes), ['dois']);
      expect(find.byType(TerminalPane), findsOneWidget);
      store.dispose();
    });

    testWidgets('e um terceiro pela borda do segundo cabe do lado dele', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store);

      await dropOnPane(tester, 'dois', x: 0.95, y: 0.5);
      // Agora são dois painéis; o alvo é a borda direita do da direita.
      final right = tester.getRect(find.byType(TerminalPane).last);
      final start = tester.getTopLeft(find.text('tres')) + const Offset(4, 4);
      final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(Offset(right.right - 20, right.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(Panes.order(store.panes), ['um', 'dois', 'tres']);
      // Uma fileira de três, não um par com um par dentro.
      expect((store.panes as PaneSplit).children.length, 3);
      store.dispose();
    });

    // A borda não promete o que a janela não tem: sem largura pros dois
    // pedaços, ela deixa de oferecer a divisão em vez de aceitá-la e devolver
    // dois painéis ilegíveis.
    testWidgets('num painel que não cabe em dois, a borda vira o meio', (tester) async {
      final store = storeWith(['um', 'dois', 'tres']);
      await pumpWindow(tester, store, width: 1060);

      await dropOnPane(tester, 'dois', x: 0.97, y: 0.5);

      expect(Panes.order(store.panes), ['dois']);
      store.dispose();
    });
  });
}
