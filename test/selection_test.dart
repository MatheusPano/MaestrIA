import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/vt.dart';
import 'package:maestria/ui/terminal_pane.dart';
import 'package:xterm/xterm.dart';

/// Um painel de terminal sozinho na janela, e a sessão dele.
Future<MxTab> pumpPane(WidgetTester tester) async {
  final store = AppStore();
  final tab = MxTab(
    id: 'tab1',
    folder: Folder(root: '/repo', name: 'meu-repo'),
    kind: TabKind.claude,
    cwd: '/repo',
    branch: '',
  );
  store.tabs.add(tab);
  store.panes = PaneLeaf(tab.id);
  store.focusedPaneId = tab.id;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 720,
          height: 320,
          child: TerminalPane(store: store, tab: tab),
        ),
      ),
    ),
  );
  await tester.pump();
  return tab;
}

/// Onde a célula [cell] está na janela: o meio dela, que é onde o mouse cai
/// quando se clica "em cima" de uma letra.
Offset centerOf(WidgetTester tester, CellOffset cell) {
  final render = tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;
  final size = render.cellSize;
  return render.localToGlobal(render.getOffset(cell)) +
      Offset(size.width / 2, size.height / 2);
}

/// O que está escrito na linha [y], sem o resto da fileira que ninguém pintou.
String lineText(Terminal terminal, int y) => terminal.buffer.lines[y].toString().trimRight();

void main() {
  group('arrastar o mouse', () {
    // O relato: "seleciono uma região e ele acende muito mais acima ou muito
    // mais abaixo". O `/clear` do claude é um `ESC[3J`, e depois dele as
    // linhas que sobraram na tela diziam a fila que tinham antes do corte --
    // que é a fila em que a seleção acendia. Ver `services/vt.dart`.
    testWidgets('acende na linha em que o mouse está, mesmo depois do /clear', (tester) async {
      final tab = await pumpPane(tester);
      final terminal = tab.term.terminal;

      for (var i = 0; i < 40; i++) {
        terminal.write('linha $i\r\n');
      }
      terminal.write('\x1b[3J');
      await tester.pump();

      const row = 3;
      final text = lineText(terminal, row);
      final from = centerOf(tester, const CellOffset(0, row));
      final to = centerOf(tester, CellOffset(text.length - 1, row));
      await tester.dragFrom(from, to - from, kind: PointerDeviceKind.mouse);
      await tester.pump();

      final selection = tab.term.controller.selection;
      expect(selection, isNotNull);
      expect(selection!.begin.y, row);
      expect(selection.end.y, row);
      expect(selectedText(terminal, selection), text);
    });

    testWidgets('e na linha em que o mouse está quando nada foi apagado', (tester) async {
      final tab = await pumpPane(tester);
      final terminal = tab.term.terminal;

      for (var i = 0; i < 40; i++) {
        terminal.write('linha $i\r\n');
      }
      await tester.pump();

      final row = terminal.buffer.lines.length - 3;
      final text = lineText(terminal, row);
      final from = centerOf(tester, CellOffset(0, row));
      final to = centerOf(tester, CellOffset(text.length - 1, row));
      await tester.dragFrom(from, to - from, kind: PointerDeviceKind.mouse);
      await tester.pump();

      final selection = tab.term.controller.selection;
      expect(selection, isNotNull);
      expect(selection!.begin.y, row);
      expect(selectedText(terminal, selection), text);
    });
  });
}
