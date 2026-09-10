/// Three things xterm 4.0.0 gets wrong about the bytes a TUI writes, one about
/// the bytes we write back, and one about reading the screen out again.
///
/// They all show up as the same complaint — "o texto do Claude fica todo
/// negrito e sublinhado aqui, mas no terminal normal fica normal" — and they
/// are all in the emulator, not in the font:
///
///  * **`SGR 22`.** `ESC[1m` opens bold and `ESC[22m` closes it: 22 is *normal
///    intensity*, so it has to clear bold **and** faint. The parser maps it to
///    `unsetCursorFaint()` alone (`escape/parser.dart`, `case 22`), leaving
///    bold on until something writes a full `ESC[0m`. A renderer that changes
///    colour per token with `ESC[38;5;N`/`ESC[39m` instead of resetting — which
///    is what Claude Code does — never writes that reset, so the first bold
///    word turns the rest of the paragraph bold. [VtTerminal] fixes this.
///
///  * **The private prefix on `CSI m`.** `ESC[>4;2m` is XTMODKEYS
///    (modifyOtherKeys): a keyboard setting, invisible in a real terminal. The
///    parser consumes the `>` into `_csi.prefix` and then dispatches to the SGR
///    handler *without looking at it*, so the parameters are read as display
///    attributes — `4` is underline and `2` is faint. Claude Code writes it
///    when the TUI starts and when it restarts (which is what `/resume` does),
///    and from there everything is underlined. [VtScrubber] drops it.
///
///  * **`DECRST 1049`.** Leaving the alternate screen restores the cursor the
///    way in saved, attributes included — that restore *is* what `ESC[?1049l`
///    means, and it is why a TUI never resets anything on its way out (Claude
///    Code's writes `ESC[?1049l` and nothing else). The parser only swaps
///    buffers (`case 1049`), and `cursor` is one style for both of them, so
///    whatever attribute the TUI happened to have open when it left keeps
///    applying to everything the pane writes afterwards. That is the other
///    half of "tudo sublinhado": not a missing `ESC[24m`, a missing restore.
///    [VtTerminal] fixes this too.
///
///  * **The input method's commit, counted more than once.** On Linux with
///    ibus — the default on Ubuntu, and on Zorin — one composed character
///    (`´` then `a`) reaches Flutter as three `updateEditingValue` calls in a
///    row, all three carrying the same finished `á`. xterm works out what was
///    typed by assuming the platform's editing model is empty again after
///    every commit (`text.substring(initState.length)` in
///    `custom_text_edit.dart`), and the reset it asks for is a message like
///    any other: the updates that arrive before it lands are read as fresh
///    typing, and claude is handed `ááá`. [VtTerminal.textInput] counts one.
///
///  * **The cells nobody wrote in.** A TUI does not pay for its blanks: it
///    puts a word down, jumps the cursor to the column of the next one with
///    `ESC[<n>G` and puts that one down, leaving every cell in between at
///    zero. `buffer.getText` writes *nothing at all* for a cell whose
///    codepoint is zero (`buffer/line.dart`, `if (codePoint != 0)`), so a
///    copied line of Claude Code's output reaches the other end as
///    `Tip:writecode` — every space in it was a cursor move, and none of them
///    survived the clipboard. [selectedText] reads them as the spaces they
///    are on screen.
///
/// None has a hook to override, so one is fixed on the stream, before the
/// parser gets to see it, two on the terminal on the way out and one on the
/// way in — and the last one by reading the buffer here instead of asking it.
library;

import 'package:xterm/xterm.dart';

/// A [Terminal] that reads `ESC[22m` and `ESC[?1049l` the way every other
/// terminal does — and that counts a typed character once.
class VtTerminal extends Terminal {
  VtTerminal({
    super.maxLines,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform,
    super.inputHandler,
    super.mouseHandler,
    super.onPrivateOSC,
    super.reflowEnabled,
    super.wordSeparators,
  });

  /// `SGR 22` — normal intensity, which is bold off as much as it is faint off.
  @override
  void unsetCursorFaint() {
    super.unsetCursorFaint();
    unsetCursorBold();
  }

  /// Back from the alternate screen: the attributes come back with it.
  ///
  /// Reset and not the saved style because the saved *position* must not come
  /// with it: `saveCursor` is one call for both, the main buffer's cursor is
  /// where the shell left it, and a prompt about to launch a TUI is not
  /// halfway through an attribute anyway.
  @override
  void useMainBuffer() {
    super.useMainBuffer();
    resetCursorStyle();
  }

  /// A key went down, so the next text to arrive was typed by someone.
  ///
  /// Called by the pane that holds the keyboard (see `terminal_pane.dart`),
  /// from before the focus tree gets the event — xterm hides the keys that
  /// arrive with a composition open, and those are exactly the ones a composed
  /// character is spending.
  ///
  /// A keystroke is worth one insertion and no more, which is the whole trick:
  /// however many keys go down before the system finally commits something,
  /// what comes out is one character.
  void keyWentDown() => _unspentKey = true;

  /// A keystroke that has not yet been answered by text.
  bool _unspentKey = false;

  /// The last text that actually went to the pty.
  String? _lastInput;

  /// The typed character, once, however many times the system delivers it.
  ///
  /// See the fourth item at the top of this library. What separates ibus's
  /// repeats from someone really typing the same letter twice is that no key
  /// went down in between — pressing `á` twice is four keystrokes, and each
  /// one of them arrives here first.
  ///
  /// Empty text is dropped before any of that: an update that carries only a
  /// composition in progress arrives as an empty string, it has no byte to
  /// send, and letting it through would spend the keystroke that the composed
  /// character is still waiting for.
  @override
  void textInput(String text) {
    if (text.isEmpty) return;
    if (!_unspentKey && text == _lastInput) return;
    _unspentKey = false;
    _lastInput = text;
    super.textInput(text);
  }

  /// What the app writes on its own account: a wheel notch, `^V`, ESC+CR.
  ///
  /// No keystroke has to vouch for these, and they are meant to repeat — a
  /// wheel turned three notches is the same report three times. [textInput] is
  /// for what a person typed; this is for what the app said.
  void send(String data) {
    _lastInput = null;
    super.textInput(data);
  }

  /// A paste is never an echo, however much it repeats what came before it.
  @override
  void paste(String text) {
    _lastInput = null;
    super.paste(text);
  }
}

/// The text of [range], with the blanks a TUI never wrote down.
///
/// See the last item at the top of this library: to `buffer.getText` a cell
/// that was never written to is not a space, it is nothing, and a screen a TUI
/// laid out with cursor jumps is mostly those. Here an empty cell inside the
/// selection is the space it looks like.
///
/// The empty ones at the *end* of a line are not: those are the rest of a row
/// nobody drew on, and no terminal puts them on the clipboard. A space the
/// program actually wrote stays wherever it is — it was selected like any
/// other character.
String selectedText(Terminal terminal, BufferRange range) {
  final buffer = terminal.buffer;
  final selection = range.normalized;
  final lines = <StringBuffer>[StringBuffer()];

  for (final segment in selection.toSegments()) {
    if (segment.line < 0 || segment.line >= buffer.height) continue;
    final line = buffer.lines[segment.line];
    // A wrapped line is the second half of the line above it, so it joins
    // without a break -- the rule `buffer.getText` follows, and the reason a
    // URL that the terminal split in two is copied whole.
    if (!(segment.line == selection.begin.y || segment.line == 0 || line.isWrapped)) {
      lines.add(StringBuffer());
    }
    lines.last.write(_segmentText(line, segment.start, segment.end));
  }

  return lines.join('\n');
}

/// One line of [selectedText], from cell [start] up to (not including) [end].
String _segmentText(BufferLine line, int? start, int? end) {
  final from = (start == null || start < 0) ? 0 : start;
  final to = (end == null || end > line.length) ? line.length : end;

  // Where the drawn part ends: past this every empty cell is the row's own
  // padding, and not a gap between two words.
  var drawn = to;
  while (drawn > from && line.getCodePoint(drawn - 1) == 0) {
    drawn--;
  }

  final out = StringBuffer();
  for (var i = from; i < drawn; i++) {
    final codePoint = line.getCodePoint(i);
    if (codePoint == 0) {
      // The cell behind a wide character is empty too, and it is not a gap:
      // the `日` before it is already occupying this column.
      if (i > 0 && line.getWidth(i - 1) == 2) continue;
      out.write(' ');
      continue;
    }
    // A wide character the selection cuts in half is not in the selection.
    if (i + line.getWidth(i) <= to) out.writeCharCode(codePoint);
  }
  return out.toString();
}

/// Drops the `CSI` sequences that xterm would read as display attributes.
///
/// A private prefix (`<`, `=` or `>`) means the sequence is not SGR at all, so
/// the ones that end in `m` are thrown away: `ESC[>4;2m` and `ESC[>4m` are the
/// only ones a TUI writes in practice, and they are settings the emulator does
/// not implement either way. Anything else — including `ESC[>c`, the secondary
/// device attributes *question*, whose answer a TUI waits for — passes through
/// untouched.
///
/// The pty hands over whatever the read returned, so a sequence can arrive
/// split across two chunks. A trailing fragment that might still turn into one
/// of these is held back until the next chunk completes it, up to
/// [_maxFragment] characters — past that it is not a sequence anyone is
/// writing, and holding it would swallow output.
class VtScrubber {
  static const _maxFragment = 32;

  String _held = '';

  /// [chunk] with the offending sequences removed, minus any tail being held.
  String call(String chunk) {
    final input = _held.isEmpty ? chunk : '$_held$chunk';
    _held = '';

    final out = StringBuffer();
    var cursor = 0;
    while (cursor < input.length) {
      final csi = input.indexOf('\x1b[', cursor);
      if (csi < 0) {
        // A lone ESC at the end may be the head of a sequence that is still
        // being written.
        final esc = input.endsWith('\x1b') ? input.length - 1 : input.length;
        out.write(input.substring(cursor, esc));
        _held = input.substring(esc);
        break;
      }

      out.write(input.substring(cursor, csi));

      // The prefix is the byte that decides, and it may not be here yet.
      if (csi + 2 >= input.length) {
        _hold(out, input, csi);
        break;
      }
      if (!_isPrivatePrefix(input.codeUnitAt(csi + 2))) {
        out.write('\x1b[');
        cursor = csi + 2;
        continue;
      }

      var end = csi + 3;
      while (end < input.length && !_isFinalByte(input.codeUnitAt(end))) {
        end++;
      }
      if (end == input.length) {
        _hold(out, input, csi);
        break;
      }

      // Only `m` is a display sequence to xterm. Everything else is itself.
      if (input.codeUnitAt(end) != 0x6d) {
        out.write(input.substring(csi, end + 1));
      }
      cursor = end + 1;
    }

    return out.toString();
  }

  /// Keeps an unfinished sequence for the next chunk — or gives up on it.
  void _hold(StringBuffer out, String input, int start) {
    final fragment = input.substring(start);
    if (fragment.length > _maxFragment) {
      out.write(fragment);
    } else {
      _held = fragment;
    }
  }

  /// `<`, `=`, `>` — the prefixes that make a `CSI` sequence private.
  static bool _isPrivatePrefix(int char) => char >= 0x3c && char <= 0x3e;

  /// The byte that ends a `CSI` sequence: anything in `@`..`~`.
  static bool _isFinalByte(int char) => char >= 0x40 && char <= 0x7e;
}
