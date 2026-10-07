import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/models.dart';
import 'package:maestria/services/layout.dart';
import 'package:maestria/services/store.dart';
import 'package:maestria/services/vt.dart';
import 'package:maestria/ui/terminal_pane.dart';
import 'package:xterm/xterm.dart';

/// A terminal 40 columns wide, which is room enough for a line of a TUI.
VtTerminal screen() {
  final terminal = VtTerminal(maxLines: 100);
  terminal.resize(40, 6);
  return terminal;
}

/// What ⌘C would put on the clipboard, selecting [from] up to [to] on [line].
String copied(Terminal terminal, {int from = 0, int? to, int line = 0, int? lastLine}) {
  final range = BufferRangeLine(
    CellOffset(from, line),
    CellOffset(to ?? terminal.viewWidth, lastLine ?? line),
  );
  return selectedText(terminal, range);
}

/// Everything the app put on the clipboard, in order.
List<String> watchClipboard() {
  final written = <String>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          written.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
  return written;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Uma TUI não paga pelos brancos dela: escreve uma palavra, salta o cursor
  // pra coluna da próxima e escreve essa. As células no meio nunca foram
  // escritas, e pro `buffer.getText` do xterm elas não são espaço nenhum --
  // são nada. Ver [selectedText].
  group('selectedText', () {
    test('the columns a TUI jumped over are the spaces they look like', () {
      final terminal = screen();
      terminal.write('\x1b[H\x1b[1GTip:\x1b[10Gwrite\x1b[20Gcode');

      expect(copied(terminal), 'Tip:     write     code');
    });

    test('and factory xterm is the one that gets it wrong -- the ruler', () {
      final terminal = Terminal(maxLines: 100)..resize(40, 6);
      terminal.write('\x1b[H\x1b[1GTip:\x1b[10Gwrite\x1b[20Gcode');

      final range = BufferRangeLine(const CellOffset(0, 0), const CellOffset(40, 0));
      expect(terminal.buffer.getText(range), 'Tip:writecode');
    });

    test('the empty rest of the row is not selected text', () {
      final terminal = screen();
      terminal.write('\x1b[Hgit status');

      expect(copied(terminal), 'git status');
    });

    test('a space the program did write stays where it is', () {
      final terminal = screen();
      terminal.write('\x1b[H  a  b');

      expect(copied(terminal), '  a  b');
    });

    // A célula de trás de um caractere largo também está vazia, e ela não é
    // um vão: o `日` da frente já ocupa esta coluna.
    test('a wide character does not drag a space behind it', () {
      final terminal = screen();
      terminal.write('\x1b[H日本 x');

      expect(copied(terminal), '日本 x');
    });

    test('nor does one the selection cuts in half come along', () {
      final terminal = screen();
      terminal.write('\x1b[Ha日');

      expect(copied(terminal, to: 2), 'a');
    });

    test('two lines are two lines', () {
      final terminal = screen();
      terminal.write('\x1b[Hum\r\ndois');

      expect(copied(terminal, lastLine: 1), 'um\ndois');
    });

    // Uma linha quebrada é a segunda metade da de cima: é o que faz uma URL
    // longa ser copiada inteira, e não com um \n no meio.
    test('but a line the terminal wrapped is one line', () {
      final terminal = VtTerminal(maxLines: 100)..resize(10, 6);
      terminal.write('\x1b[H0123456789abcde');

      expect(copied(terminal, lastLine: 1), '0123456789abcde');
    });
  });

  // Como o Claude Code 2.1.292 escreve: continuação na coluna 3, via `ESC[2C`.
  group('selectedText with reflow', () {
    VtTerminal claude(List<String> rows, {int width = 40}) {
      final terminal = VtTerminal(maxLines: 100)..resize(width, 12);
      terminal.write('\x1b[H● ${rows.first}');
      for (final row in rows.skip(1)) {
        terminal.write('\r\n${row.isEmpty ? '' : '\x1b[2C$row'}');
      }
      return terminal;
    }

    String reflowed(Terminal terminal, {int from = 0, int line = 0, required int lastLine}) =>
        selectedText(
          terminal,
          BufferRangeLine(CellOffset(from, line), CellOffset(terminal.viewWidth, lastLine)),
          reflow: true,
        );

    test('the rows Claude broke join into one line, without the indent or the ●', () {
      final terminal = claude([
        'Rivers shape landscapes and sustain',
        'ecosystems across the whole globe.',
      ]);

      expect(
        reflowed(terminal, lastLine: 1),
        'Rivers shape landscapes and sustain ecosystems across the whole globe.',
      );
    });

    test('and without reflow they stay as the screen shows them', () {
      final terminal = claude([
        'Rivers shape landscapes and sustain',
        'ecosystems across the whole globe.',
      ]);

      final range = BufferRangeLine(const CellOffset(0, 0), const CellOffset(40, 1));
      expect(
        selectedText(terminal, range),
        '● Rivers shape landscapes and sustain\n  ecosystems across the whole globe.',
      );
    });

    test('a row that ends early ends a line', () {
      final terminal = claude(['First paragraph.', '', 'Second one.']);

      expect(reflowed(terminal, lastLine: 2), 'First paragraph.\n\nSecond one.');
    });

    test('a row whose next word would have fit was a line of its own', () {
      final terminal = claude(['Short line', 'x']);

      expect(reflowed(terminal, lastLine: 1), 'Short line\nx');
    });

    test('list items stay apart, each one whole', () {
      final terminal = claude([
        'Two items:',
        '',
        '- The first item is long enough to',
        '  wrap.',
        '- The second.',
      ]);

      expect(
        reflowed(terminal, lastLine: 4),
        'Two items:\n\n- The first item is long enough to wrap.\n- The second.',
      );
    });

    test('a selection that starts on a word keeps the rest dedented', () {
      final terminal = claude([
        'Rivers shape landscapes and sustain',
        'ecosystems.',
        '',
        '- An item.',
      ]);

      expect(
        reflowed(terminal, from: 9, lastLine: 3),
        'shape landscapes and sustain ecosystems.\n\n- An item.',
      );
    });

    test('a word longer than the row joins without a space', () {
      final terminal = claude(['https://example.com/a/very/long/path/x', 'yz']);

      expect(reflowed(terminal, lastLine: 1), 'https://example.com/a/very/long/path/xyz');
    });

    test('a row that opens with a number is still the middle of a sentence', () {
      final terminal = claude([
        'The release shipped in the spring of',
        '2026. After that the whole team had',
        'moved on.',
      ]);

      expect(
        reflowed(terminal, lastLine: 2),
        'The release shipped in the spring of 2026. After that the whole team had moved on.',
      );
    });

    test('a selection across two replies loses both ●', () {
      final terminal = claude(['First reply.', '', '\x1b[1G● Second reply.', '  - item']);

      expect(reflowed(terminal, lastLine: 3), 'First reply.\n\nSecond reply.\n- item');
    });

    test('a selection that starts on the space between two words is not an indent', () {
      final terminal = claude([
        'Rivers shape landscapes and sustain',
        'ecosystems.',
        '',
        '- An item.',
      ]);

      expect(
        reflowed(terminal, from: 8, lastLine: 3),
        ' shape landscapes and sustain ecosystems.\n\n- An item.',
      );
    });

    test('a table is never prose', () {
      final terminal = claude([
        '┌──────────────────────────────────┐',
        '│ a long table row that fills it  │',
        '└──────────────────────────────────┘',
      ]);

      expect(reflowed(terminal, lastLine: 2).split('\n'), hasLength(3));
    });
  });

  group('⌘C', () {
    testWidgets('copies the selection, spaces and all', (tester) async {
      final clipboard = watchClipboard();
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

      final terminal = tab.term.terminal;
      terminal.write('\x1b[H\x1b[1GTip:\x1b[10Gwrite');
      tab.term.controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(14, 0),
      );

      await simulateKeyDownEvent(LogicalKeyboardKey.meta);
      await simulateKeyDownEvent(LogicalKeyboardKey.keyC);
      await simulateKeyUpEvent(LogicalKeyboardKey.keyC);
      await simulateKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pump();

      expect(clipboard, ['Tip:     write']);
    });
  });
}
