import 'package:flutter_test/flutter_test.dart';
import 'package:maestria/services/pty.dart';
import 'package:xterm/xterm.dart';

/// Everything the session would have written to its pty.
List<String> watch(TermSession session) {
  final written = <String>[];
  session.terminal.onOutput = written.add;
  return written;
}

/// What claude writes before it paints anything: the alternate screen, then
/// mouse reporting -- click, drag, motion, and the SGR encoding for all three.
void claudeAsksForTheMouse(TermSession session) {
  session.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
}

void main() {
  group('a notch of the wheel', () {
    test('is reported as the spec has it, not as xterm has it', () {
      final session = TermSession();
      final written = watch(session);

      claudeAsksForTheMouse(session);
      session.wheel(up: true, col: 0, row: 0);
      session.wheel(up: false, col: 0, row: 0);

      // 68 and 69 -- what xterm sends -- are these two with the shift bit set.
      expect(written, ['\x1b[<64;1;1M', '\x1b[<65;1;1M']);
    });

    test('names the cell it happened over, counting from one', () {
      final session = TermSession();
      final written = watch(session);

      claudeAsksForTheMouse(session);
      session.wheel(up: false, col: 41, row: 7);

      expect(written, ['\x1b[<65;42;8M']);
    });

    test('becomes an arrow key when the program never asked for the mouse', () {
      final session = TermSession();
      final written = watch(session);

      // The alternate screen, and nothing else: a pager, not claude.
      session.terminal.write('\x1b[?1049h');
      session.wheel(up: true, col: 3, row: 3);

      expect(written.single, anyOf('\x1b[A', '\x1bOA'));
    });
  });

  group('xterm', () {
    test('no longer reports the wheel itself', () {
      final session = TermSession();
      final written = watch(session);

      claudeAsksForTheMouse(session);
      final handled = session.terminal.mouseInput(
        TerminalMouseButton.wheelUp,
        TerminalMouseButtonState.down,
        const CellOffset(0, 0),
      );

      expect(handled, isFalse);
      expect(written, isEmpty);
    });

    test('but still reports the buttons', () {
      final session = TermSession();
      final written = watch(session);

      claudeAsksForTheMouse(session);
      final handled = session.terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        const CellOffset(0, 0),
      );

      expect(handled, isTrue);
      expect(written, isNotEmpty);
    });
  });
}
