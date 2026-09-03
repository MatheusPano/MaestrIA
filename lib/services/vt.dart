/// Three things xterm 4.0.0 gets wrong about the bytes a TUI writes.
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
/// None has a hook to override, so one is fixed on the stream, before the
/// parser gets to see it, and the others on the terminal, after it.
library;

import 'package:xterm/xterm.dart';

/// A [Terminal] that reads `ESC[22m` and `ESC[?1049l` the way every other
/// terminal does.
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
