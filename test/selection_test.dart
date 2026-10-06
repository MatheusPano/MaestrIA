import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/pty.dart';
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

/// Uma tela de claude: a tela alternativa, com [rows] fileiras de transcript
/// pintadas uma a uma a partir de [first] — `msg 7`, `msg 8`, ... —, do jeito
/// que um TUI redesenha: posiciona o cursor, escreve, apaga o resto.
String frame(int first, {int rows = 20}) =>
    [for (var y = 0; y < rows; y++) '\x1b[${y + 1};1Hmsg ${first + y} do transcript\x1b[K'].join();

/// Seleciona do começo da fileira [row] até o fim de [to] (ou da própria). A
/// fileira inteira: o branco que sobra no fim [selectedText] já deixa de fora.
void select(TermSession term, int row, {int? to}) {
  final buffer = term.terminal.buffer;
  final last = to ?? row;
  term.controller.setSelection(
    buffer.createAnchor(0, row),
    buffer.createAnchor(buffer.lines[last].length, last),
  );
}

String? selected(TermSession term) {
  final range = term.controller.selection;
  return range == null ? null : selectedText(term.terminal, range);
}

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

  group('rolar com texto selecionado na tela alternativa', () {
    // O relato: "seleciono um texto e scrollo, e a seleção não fica naquele
    // texto, ela acompanha a tela". Ver `services/sticky_selection.dart`.
    testWidgets('a seleção acompanha o texto quando o programa redesenha', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0)}');
      select(term, 5);
      expect(selected(term), 'msg 5 do transcript');

      // Três notches pra baixo: o claude pinta as mesmas fileiras, três
      // mensagens adiante.
      term.terminal.write(frame(3));
      await tester.pump(const Duration(milliseconds: 50));

      expect(selected(term), 'msg 5 do transcript');
      expect(term.controller.selection!.begin.y, 2);

      // E de volta pra cima, mais longe do que veio.
      term.terminal.write(frame(-4));
      await tester.pump(const Duration(milliseconds: 50));

      expect(selected(term), 'msg 5 do transcript');
      expect(term.controller.selection!.begin.y, 9);
    });

    // O que o log do app mostrou: o claude pula o cursor por cima de um
    // espaço na primeira vez e o escreve na seguinte, e pro xterm a mesma
    // frase vira outra.
    testWidgets('um espaço pulado e um espaço escrito são o mesmo texto', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0)}');
      term.terminal.write('\x1b[6;1H\x1b[2Kuma\x1b[6;5Hfrase\x1b[6;11Hcom\x1b[6;15Hburacos\x1b[K');
      select(term, 5);

      term.terminal.write(frame(3));
      term.terminal.write('\x1b[3;1Huma frase com buracos\x1b[K');
      await tester.pump(const Duration(milliseconds: 50));

      expect(term.controller.selection, isNotNull);
      expect(term.controller.selection!.begin.y, 2);
      expect(selected(term), 'uma frase com buracos');
    });

    testWidgets('várias fileiras andam juntas', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0)}');
      select(term, 4, to: 6);
      final before = selected(term);

      term.terminal.write(frame(2));
      await tester.pump(const Duration(milliseconds: 50));

      expect(selected(term), before);
      expect(term.controller.selection!.begin.y, 2);
      expect(term.controller.selection!.end.y, 4);
    });

    testWidgets('e também quando ele rola com sequência de scroll', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0, rows: 24)}');
      select(term, 10);

      // `CSI 3 S`: o xterm move as linhas, e no caminho desanexa as âncoras.
      term.terminal.write('\x1b[3S');
      await tester.pump(const Duration(milliseconds: 50));

      expect(selected(term), 'msg 10 do transcript');
      expect(term.controller.selection!.begin.y, 7);
    });

    testWidgets('um quadro que chega em dois pedaços não derruba a seleção', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0)}');
      select(term, 12);

      // O claude apaga a tela antes de repintar: no meio do caminho o texto
      // selecionado não está em lugar nenhum.
      final next = frame(3);
      final half = next.indexOf('\x1b[6;1H');
      term.terminal.write('\x1b[2J${next.substring(0, half)}');
      await tester.pump(const Duration(milliseconds: 50));
      term.terminal.write(next.substring(half));
      await tester.pump(const Duration(milliseconds: 300));

      expect(selected(term), 'msg 12 do transcript');
      expect(term.controller.selection!.begin.y, 9);
    });

    testWidgets('o texto que saiu da tela leva a seleção com ele', (tester) async {
      final term = TermSession();
      term.terminal.write('\x1b[?1049h${frame(0)}');
      select(term, 1);

      term.terminal.write(frame(10));
      await tester.pump(const Duration(milliseconds: 300));

      expect(term.controller.selection, isNull);
    });

    testWidgets('na tela principal a seleção é do xterm, e fica onde está', (tester) async {
      final term = TermSession();
      for (var i = 0; i < 10; i++) {
        term.terminal.write('linha $i\r\n');
      }
      select(term, 3);

      term.terminal.write('\x1b[4;1Houtra coisa\x1b[K');
      await tester.pump(const Duration(milliseconds: 300));

      expect(term.controller.selection, isNotNull);
      expect(term.controller.selection!.begin.y, 3);
    });
  });
}
