import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'links.dart';
import 'shell.dart';
import 'vt.dart';

/// One real terminal: a pty child wired to an xterm buffer.
///
/// Commands run as `zsh -lc 'exec <cmd>'`. The login shell supplies the PATH a
/// GUI process does not inherit, and `exec` replaces the shell with the target
/// so `pty.pid` is the pid of `claude` itself -- which is what lets a tab be
/// matched against a row of `claude agents --json`.
class TermSession {
  TermSession({int scrollback = 8000})
    : terminal = VtTerminal(maxLines: scrollback, mouseHandler: _mouseWithoutWheel) {
    links = TermLinks(terminal);
  }

  final VtTerminal terminal;
  final TerminalController controller = TerminalController();

  /// Os links que o programa marcou ele mesmo. Ver [TermLinks].
  late final TermLinks links;

  /// The pty's bytes, minus the sequences xterm reads as display attributes.
  final VtScrubber _scrub = VtScrubber();
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

  /// Roda o comando outra vez neste mesmo painel, depois que o processo saiu.
  ///
  /// O scrollback fica: o que o programa deixou escrito antes de sair é
  /// justamente o que se quer ler quando ele sai sozinho. Só com o processo
  /// morto -- um pty vivo aqui daria dois filhos escrevendo no mesmo buffer, e
  /// o `exitCode` do primeiro chegaria depois do segundo subir, marcando como
  /// morto um painel que acabou de nascer.
  void relaunch(String command, String cwd) {
    if (!exited) return;
    exited = false;
    exitCode = null;
    terminal.write('\r\n');
    startCommand(command, cwd);
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
      environment: {...Platform.environment, ..._capabilities, ...?env},
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );
    _pty = pty;

    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen((chunk) => terminal.write(_scrub(chunk)));
    pty.exitCode.then((code) {
      exited = true;
      exitCode = code;
      terminal.write('\r\n\x1b[2m[processo saiu com $code]\x1b[0m\r\n');
      onExit?.call();
    });

    terminal.onOutput = (data) => pty.write(const Utf8Encoder().convert(data));
    terminal.onResize = (w, h, pw, ph) => pty.resize(h, w);
  }

  /// O que este pty diz sobre si mesmo pro programa que roda dentro dele.
  ///
  /// `FORCE_HYPERLINK` é como a família do `supports-hyperlinks` pergunta se o
  /// terminal entende `OSC 8` — e o `claude` é um dos que perguntam: sem uma
  /// resposta, ele imprime `rótulo (url)` e a URL fica lá, feia mas clicável.
  /// Com ela, ele marca o link de verdade, que é o que [TermLinks] agora
  /// entende. O padrão dele é olhar `TERM_PROGRAM` e `VTE_VERSION` numa lista
  /// de terminais conhecidos, e nós não estamos em lista nenhuma; o que se
  /// herdava do ambiente era o pior dos dois mundos — no Linux, um
  /// `VTE_VERSION` do terminal de onde o app foi aberto respondia "sim" por
  /// nós, e o link marcado morria aqui sem ninguém pra ler.
  static const _capabilities = {'FORCE_HYPERLINK': '1'};

  /// ⌘C. Nothing selected is not an error -- in a terminal that is just a
  /// keypress that means nothing yet.
  ///
  /// The text is read by [selectedText] and not by `buffer.getText`, which
  /// hands over a TUI's line with every space missing -- see `vt.dart`.
  Future<void> copySelection() async {
    final selection = controller.selection;
    if (selection == null) return;
    await Clipboard.setData(ClipboardData(text: selectedText(terminal, selection)));
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
    if (imagesViaCtrlV) terminal.send('\x16');
  }

  /// A line break in the prompt, the way claude asks for one.
  ///
  /// Shift+Enter is not a key a pty ever sees: the keyboard sends the same
  /// `\r` as a bare Enter, and the difference is something the emulator has to
  /// invent. ESC+CR is the sequence claude reads as a newline -- it is what
  /// `/terminal-setup` teaches iTerm and VS Code to send.
  void newline() => terminal.send('\x1b\r');

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
    terminal.send(switch (terminal.mouseReportMode) {
      MouseReportMode.sgr => '\x1b[<$button;$x;${y}M',
      MouseReportMode.urxvt => '\x1b[${button + 32};$x;${y}M',
      // The oldest encoding of all: each number is one byte, offset by 32.
      MouseReportMode.normal || MouseReportMode.utf =>
        '\x1b[M${_byte(button)}${_byte(x)}${_byte(y)}',
    });
  }

  static String _byte(int n) => String.fromCharCode(32 + n);

  /// Quanto tempo uma sessão ganha pra atender ao hangup por bem.
  static const _grace = Duration(seconds: 3);

  /// Desliga a sessão, que é o que fechar uma janela de terminal faz.
  ///
  /// [Pty.kill] -- um `SIGTERM` seco pra `pty.pid` -- erra nisso duas vezes, e
  /// o painel que continuava na lista de processos depois de fechado era os
  /// dois erros juntos:
  ///
  ///  * **O sinal.** Um shell interativo ignora SIGTERM: está no POSIX, e o
  ///    zsh obedece -- medido, um `/bin/zsh -l` sobrevive ao TERM tanto no pid
  ///    quanto no grupo. Um painel de [startShell] fechado assim ficava no
  ///    prompt pra sempre. SIGHUP é o sinal que um terminal manda quando vai
  ///    embora, e é o que nenhum shell pode recusar.
  ///  * **O alvo.** `pty.pid` é líder de sessão -- o fork do flutter_pty chama
  ///    `setsid` --, então o grupo de processos *é* esta sessão e não segura
  ///    mais nada. `-pid` alcança o que o líder subiu e um sinal só pro líder
  ///    nunca toca: os servidores MCP do claude, o `npm run dev` que uma
  ///    ferramenta deixou rodando, o pager aberto no shell.
  ///
  /// Depois espera. Um hangup é um pedido, e o claude gasta um instante com
  /// ele gravando o transcript -- vale esperar. O que não saiu depois de
  /// [_grace] não ia sair, e leva SIGKILL, que nada sobrevive.
  Future<void> kill() async {
    final pty = _pty;
    if (pty == null || exited) return;
    if (!_signal(pty, ProcessSignal.sighup)) return;
    await Future.any<void>([pty.exitCode, Future<void>.delayed(_grace)]);
    if (!exited) _signal(pty, ProcessSignal.sigkill);
  }

  /// O hangup sozinho: sem espera e sem nada pra aguardar.
  ///
  /// Pro caminho que não pode esperar -- o app sendo encerrado --, onde toda
  /// sessão precisa ser avisada antes que o processo que faria a escalada
  /// deixe de existir.
  void hangUp() {
    final pty = _pty;
    if (pty != null && !exited) _signal(pty, ProcessSignal.sighup);
  }

  /// Sinaliza a sessão inteira, caindo pro líder sozinho quando não há grupo
  /// pra sinalizar. `false` é não ter sobrado nada pra receber o sinal.
  bool _signal(Pty pty, ProcessSignal signal) {
    final pid = pty.pid;
    // `kill(-1)` é todo processo do usuário e `kill(0)` é o grupo deste app:
    // um pid que não existe mais não pode virar nenhum dos dois.
    if (pid <= 1) return false;
    // Negativo é o grupo de processos -- ver [kill].
    return Process.killPid(-pid, signal) || Process.killPid(pid, signal);
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
