import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'shell.dart';

/// One real terminal: a pty child wired to an xterm buffer.
///
/// Commands run as `zsh -lc 'exec <cmd>'`. The login shell supplies the PATH a
/// GUI process does not inherit, and `exec` replaces the shell with the target
/// so `pty.pid` is the pid of `claude` itself -- which is what lets a tab be
/// matched against a row of `claude agents --json`.
class TermSession {
  TermSession({int scrollback = 8000})
    : terminal = Terminal(maxLines: scrollback, mouseHandler: _mouseWithoutWheel);

  final Terminal terminal;
  final TerminalController controller = TerminalController();
  Pty? _pty;
  bool exited = false;
  int? exitCode;
  void Function()? onExit;

  int? get pid => _pty?.pid;

  void startShell(String cwd) => _start(['-l'], cwd, null);

  void startCommand(String command, String cwd, {Map<String, String>? env, String? display}) {
    note(display ?? command);
    _start(['-lc', 'exec $command'], cwd, env);
  }

  /// A dim line in the buffer itself, so the exact command is never a mystery.
  void note(String text) => terminal.write('\x1b[2m\$ $text\x1b[0m\r\n');

  void _start(List<String> args, String cwd, Map<String, String>? env) {
    // Never hand the pty a folder that is not there.
    //
    // flutter_pty's child ignores a failed `chdir` (flutter_pty_unix.c) and
    // goes on to exec anyway -- so a missing cwd used to start the session in
    // whatever directory the .app happens to be in, and the forked child that
    // fails to exec falls through into the parent's code path. Refusing here
    // is cheap; the panel says why, and the app stays up.
    if (!Directory(cwd).existsSync()) {
      exited = true;
      exitCode = -1;
      terminal.write('\x1b[31ma pasta $cwd não existe — nada foi iniciado.\x1b[0m\r\n');
      // The caller wires onExit right after asking for the start, so the
      // notification has to wait for it to get there.
      Future.microtask(() => onExit?.call());
      return;
    }

    final pty = Pty.start(
      Sh.shell,
      arguments: args,
      workingDirectory: cwd,
      environment: {...Platform.environment, ...?env},
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _pty = pty;

    pty.output.cast<List<int>>().transform(const Utf8Decoder()).listen(terminal.write);
    pty.exitCode.then((code) {
      exited = true;
      exitCode = code;
      terminal.write('\r\n\x1b[2m[processo saiu com $code]\x1b[0m\r\n');
      onExit?.call();
    });

    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  /// ⌘C. Nothing selected is not an error -- in a terminal that is just a
  /// keypress that means nothing yet.
  Future<void> copySelection() async {
    final selection = controller.selection;
    if (selection == null) return;
    await Clipboard.setData(ClipboardData(text: terminal.buffer.getText(selection)));
  }

  /// What ⌘V puts in.
  ///
  /// Text goes in as a paste, bracketed when the program asked for that, so a
  /// multi-line block arrives as one block instead of a run of enters.
  ///
  /// An image cannot travel down a pty at all. `claude` knows this and reads
  /// the screenshot off the system clipboard itself the moment it sees a ^V --
  /// so when the clipboard holds no text, that is what we send, and the paste
  /// lands in the prompt anyway.
  Future<void> pasteClipboard({bool imagesViaCtrlV = false}) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.isNotEmpty) {
      terminal.paste(text);
      controller.clearSelection();
      return;
    }
    if (imagesViaCtrlV) terminal.textInput('\x16');
  }

  /// A line break in the prompt, the way claude asks for one.
  ///
  /// Shift+Enter is not a key a pty ever sees: the keyboard sends the same
  /// `\r` as a bare Enter, and the difference is something the emulator has to
  /// invent. ESC+CR is the sequence claude reads as a newline -- it is what
  /// `/terminal-setup` teaches iTerm and VS Code to send.
  void newline() => terminal.textInput('\x1b\r');

  /// Put [text] in the prompt and send it.
  ///
  /// A paste rather than a run of keystrokes, for the same reason ⌘V is one: a
  /// multi-line instruction typed character by character submits itself on its
  /// first newline, where a bracketed paste arrives as one block. The pause is
  /// what the TUI needs to have that block in its buffer before the return
  /// lands -- without it the return hits an empty prompt and the text turns up
  /// after it.
  Future<void> submit(String text) async {
    if (exited || text.trim().isEmpty) return;
    terminal.paste(text);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (exited) return;
    terminal.keyInput(TerminalKey.enter);
  }

  /// One notch of the wheel, over the cell at [col] x [row] (both 0-based).
  ///
  /// Reported by hand because xterm 4.0 gets the wheel wrong twice, and both
  /// mistakes land on claude: it runs its whole UI in the alternate screen
  /// (`\x1b[?1049h` before it paints anything) and asks for mouse reports
  /// (`?1000h ?1002h ?1003h ?1006h`), so the wheel is the *only* way to scroll
  /// the conversation — the pane has no scrollback of its own to scroll instead.
  ///
  ///  * The button. SGR reports the wheel as 64 up and 65 down; xterm sends 68
  ///    and 69, which is 64 and 65 with the shift bit set — the wheel with a
  ///    modifier held, not the wheel.
  ///  * The cell. xterm hands its reporter the pointer's offset in the *window*
  ///    instead of in the terminal, and our panes are never at the window
  ///    origin — the sidebar and the pane header are always in front of them.
  ///    Claude routes a notch to whatever it believes the pointer is over, so a
  ///    report that names a cell tens of columns off is a report it drops.
  ///
  /// A program that never asked for mouse reports gets an arrow key instead,
  /// which is what a terminal does for a pager in the alternate screen.
  void wheel({required bool up, required int col, required int row}) {
    if (!terminal.mouseMode.reportScroll) {
      terminal.keyInput(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
      return;
    }
    final button = up ? 64 : 65;
    // Every encoding counts rows and columns from 1.
    final x = col + 1;
    final y = row + 1;
    terminal.textInput(switch (terminal.mouseReportMode) {
      MouseReportMode.sgr => '\x1b[<$button;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${button + 32};$x;${y}M',
      // The oldest encoding of all: each number is one byte, offset by 32.
      MouseReportMode.normal || MouseReportMode.utf =>
        '\x1b[M${_byte(button)}${_byte(x)}${_byte(y)}',
    });
  }

  static String _byte(int n) => String.fromCharCode(32 + n);

  void kill() {
    if (!exited) _pty?.kill();
  }
}

/// The mouse with the wheel taken off it.
///
/// [TermSession.wheel] is what reports the wheel now, and xterm must not report
/// it a second time — wrongly — behind its back. Clicks are still xterm's.
const _mouseWithoutWheel = _MouseWithoutWheel(defaultMouseHandler);

class _MouseWithoutWheel implements TerminalMouseHandler {
  const _MouseWithoutWheel(this.buttons);

  final TerminalMouseHandler buttons;

  @override
  String? call(TerminalMouseEvent event) =>
      event.button.isWheel ? null : buttons(event);
}
