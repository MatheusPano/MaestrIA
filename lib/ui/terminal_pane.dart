import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../models.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'dialogs.dart';
import 'keys.dart';
import 'panel.dart';
import 'result_strip.dart';

/// One pane: header that says what this panel is, then the pty.
///
/// Stateful only for the result strip, whose unfolded-or-not is the one thing
/// about a pane that nothing else needs to know. It is not on [MxTab] because
/// it is not worth saving and not worth restoring: a strip is a glance at what
/// just happened, and reopening the app is a fresh glance.
class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.store,
    required this.tab,
    this.focused = true,
    this.showFocus = false,
    this.onFocus,
  });

  final AppStore store;
  final MxTab tab;
  final bool focused;

  /// Only worth drawing when there are two panes to tell apart.
  final bool showFocus;
  final VoidCallback? onFocus;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  bool _resultOpen = false;

  @override
  void didUpdateWidget(TerminalPane old) {
    super.didUpdateWidget(old);
    // A pane is a position, not a panel: switching tabs hands this same widget
    // a different [MxTab]. Without the reset, opening one panel's strip would
    // leave every panel you visited afterwards unfolded.
    if (old.tab.id != widget.tab.id) _resultOpen = false;
  }

  void _clearResult() {
    setState(() {
      widget.tab.hooks.touched.clear();
      _resultOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final produced = widget.tab.hooks.touched.length;
    return Listener(
      // O clique é ouvido no ponteiro, não como gesto: o pty embaixo tem
      // reconhecedores próprios (seleção, clique) e ganha a arena de gestos
      // do miolo do painel — então um GestureDetector aqui só chegava a
      // disparar no header, e clicar no meio do terminal dava o teclado a
      // ele sem mover o anel. O Listener vê a pressão antes da arena e não
      // disputa com ninguém.
      onPointerDown: (_) => widget.onFocus?.call(),
      // The pane is a card of its own: with two open, the accent outline says
      // which one the keyboard is talking to.
      child: MxPanel(
        focused: widget.focused,
        showFocus: widget.showFocus,
        child: Column(
          children: [
            _PaneHeader(
              store: widget.store,
              tab: widget.tab,
              dimmed: widget.showFocus && !widget.focused,
              resultOpen: _resultOpen,
              onToggleResult: () => setState(() => _resultOpen = !_resultOpen),
            ),
            Expanded(
              child: _TerminalSurface(
                store: widget.store,
                tab: widget.tab,
                focused: widget.focused,
              ),
            ),
            // Costs the layout nothing until the session has written
            // something, which is the state half the panels are in.
            if (_resultOpen && produced > 0)
              ResultStrip(store: widget.store, tab: widget.tab, onClear: _clearResult),
          ],
        ),
      ),
    );
  }
}

/// The pty itself.
///
/// Stateful for the wheel's sake: reporting a notch takes the render object
/// (for the cell under the pointer) and somewhere to keep the pixels that have
/// not added up to a whole line yet — neither of which a stateless pane holds.
class _TerminalSurface extends StatefulWidget {
  const _TerminalSurface({required this.store, required this.tab, required this.focused});

  final AppStore store;
  final MxTab tab;
  final bool focused;

  @override
  State<_TerminalSurface> createState() => _TerminalSurfaceState();
}

class _TerminalSurfaceState extends State<_TerminalSurface> {
  final _view = GlobalKey<TerminalViewState>();

  /// O nó de foco do pty, nosso e não do xterm.
  ///
  /// Sem ele o único jeito de um painel pegar o teclado era o `autofocus`, que
  /// só vale no primeiro quadro: trocar de painel pelo teclado (⌃⇥, ⌘⌥↑↓)
  /// acendia o anel num painel e continuava digitando no outro. Com o nó na
  /// mão, quem passa a estar em foco pede o teclado — ver [didUpdateWidget].
  final _focus = FocusNode(debugLabel: 'terminal');

  /// Wheel movement that has not yet added up to a line.
  double _pending = 0;

  Terminal get _terminal => widget.tab.term.terminal;

  @override
  void didUpdateWidget(_TerminalSurface old) {
    super.didUpdateWidget(old);
    if (widget.focused && !old.focused) _focus.requestFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The wheel is caught above the view, not inside it: xterm's own handler
    // for the alternate screen reports it to the program with the wrong button
    // at the wrong cell (see TermSession.wheel), and `simulateScroll: false`
    // stops it from turning the wheel into arrow keys when that report fails.
    return Listener(
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _scrolled(e.scrollDelta.dy, e.position);
      },
      // A trackpad is not a wheel: two fingers on the glass arrive as their own
      // kind of event, and they push the content the way the fingers went —
      // the opposite sign of a wheel that scrolls down.
      onPointerPanZoomStart: (_) => _pending = 0,
      onPointerPanZoomUpdate: (e) => _scrolled(-e.panDelta.dy, e.position),
      child: TerminalView(
        _terminal,
        key: _view,
        controller: widget.tab.term.controller,
        focusNode: _focus,
        autofocus: widget.focused,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        // The pty paints in the app's palette, so a theme change
        // reaches the scrollback and not just the chrome around it.
        theme: Mx.terminal,
        textStyle: const TerminalStyle(
          fontSize: Mx.terminalFontSize,
          height: Mx.terminalLineHeight,
          fontFamily: Mx.mono,
        ),
        simulateScroll: false,
        onKeyEvent: _onKeyEvent,
        onSecondaryTapDown: (d, _) => showTerminalMenu(context, widget.tab, d.globalPosition),
      ),
    );
  }

  /// Turns pixels of wheel into notches and reports each one.
  ///
  /// Only in the alternate screen. Everywhere else the pane has a scrollback of
  /// its own, and there xterm's Scrollable is right to keep the wheel.
  void _scrolled(double dy, Offset pointer) {
    if (!_terminal.isUsingAltBuffer) return;

    final render = _view.currentState?.renderTerminal;
    if (render == null || render.lineHeight <= 0) return;

    _pending += dy;
    final notches = _pending ~/ render.lineHeight;
    if (notches == 0) return;
    _pending -= notches * render.lineHeight;

    // Clamped because the pointer is quite often over the padding, and a report
    // for a cell that is not on the screen is a report claude throws away.
    final at = render.getCellOffset(render.globalToLocal(pointer));
    final col = at.x.clamp(0, _terminal.viewWidth - 1);
    final row = at.y.clamp(0, _terminal.viewHeight - 1);
    for (var i = 0; i < notches.abs(); i++) {
      widget.tab.term.wheel(up: notches < 0, col: col, row: row);
    }
  }

  /// ⌘V, ahead of everything else.
  ///
  /// xterm pastes too, but it only ever asks the clipboard for text, so an
  /// image on the clipboard reaches the prompt as nothing at all. This runs
  /// first -- [TerminalView.onKeyEvent] beats the built-in shortcuts -- and
  /// hands a non-text clipboard to claude as a ^V, which is how it asks for
  /// one.
  ///
  /// The other half of this fix is in MainMenu.xib: the Edit menu that ships
  /// with the Flutter template claims ⌘V (and ⌘C, and ⌘A) as key equivalents,
  /// and AppKit resolves those against the responder chain before the
  /// keystroke is offered to any view -- with that menu in place, no handler
  /// here could ever have run.
  ///
  /// Shift+Enter goes the same way, and for a related reason: xterm's keytab
  /// ignores the shift and emits the `\r` of a plain Enter, so the prompt
  /// submits where it should have grown a line. What claude wants there is
  /// ESC+CR -- see [TermSession.newline].
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final tab = widget.tab;
    if (_newline.accepts(event, keyboard)) {
      tab.term.newline();
      return KeyEventResult.handled;
    }
    if (_paste.accepts(event, keyboard)) {
      tab.term.pasteClipboard(imagesViaCtrlV: tab.kind == TabKind.claude);
      return KeyEventResult.handled;
    }
    // O mapa de atalhos inteiro, resolvido aqui e não lá em cima: a keytab do
    // xterm resolve ⌃⇥ como um Tab e ⌥← como uma sequência de escape, de modo
    // que atalhos assim nunca chegariam a ser consultados. Como agora as
    // teclas são escolhidas na tela de configurações, não dá pra saber de
    // antemão quais delas o terminal engoliria — então todas passam por aqui.
    // O que não está no mapa segue pro pty, ⇥ e ⌃C inclusive.
    if (widget.store.keymap.match(event) case final action?) {
      MxKeys.run(action, widget.store, context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static const _paste = SingleActivator(LogicalKeyboardKey.keyV, meta: true);
  static const _newline = SingleActivator(LogicalKeyboardKey.enter, shift: true);
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.store,
    required this.tab,
    required this.dimmed,
    required this.resultOpen,
    required this.onToggleResult,
  });
  final AppStore store;
  final MxTab tab;
  final bool dimmed;
  final bool resultOpen;
  final VoidCallback onToggleResult;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      // The same menu the sidebar row offers: the header *is* this panel.
      child: GestureDetector(
        onSecondaryTapDown: (d) => showPanelMenu(context, store, tab, d.globalPosition),
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            border: Border(bottom: BorderSide(color: Mx.border)),
          ),
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: Row(
            children: [
              tab.kind == TabKind.claude
                  ? ClaudeAvatar(status: tab.status, size: 20)
                  : StatusDot(status: tab.status),
              const SizedBox(width: 9),
              // Title, chips and subtitle share one flexible block on purpose.
              //
              // Laid out as siblings of the buttons, whatever the title's flex
              // share went unused stayed unclaimed, and a Row packed to the
              // start leaves that slack at its *end* — which is why the close
              // button used to float somewhere in from the right edge instead
              // of sitting on it. Boxed here, the slack falls inside the box.
              Expanded(
                // Num painel estreito -- e a grade faz painéis estreitos --
                // sobra o nome e mais nada: as fichas e o subtítulo têm
                // largura própria, e a partir de certo ponto elas não encolhem
                // mais, elas transbordam. A lateral continua dizendo tudo.
                child: LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      Flexible(
                        child: Text(
                          tab.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ),
                      if (box.maxWidth >= 170) ...[
                        const SizedBox(width: 8),
                        if (store.projectOf(tab) case final project?)
                          _Chip(
                            text: project.name,
                            color: Mx.purple,
                            icon: Icons.workspaces_outline,
                          ),
                        if (tab.branch.isNotEmpty && tab.branch != tab.title)
                          _Chip(text: tab.branch, color: Mx.fgDim, icon: Icons.call_split),
                        if (tab.dirty > 0) _Chip(text: '${tab.dirty}', color: Mx.yellow),
                        if (tab.hooks.touched.isNotEmpty)
                          ResultChip(
                            count: tab.hooks.touched.length,
                            open: resultOpen,
                            onTap: onToggleResult,
                          ),
                        if (tab.followUps.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FollowUpMark(tab: tab),
                          ),
                        Flexible(
                          flex: 2,
                          child: Text(
                            tab.subtitle,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Mx.fgDim, fontSize: 12),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (tab.agentName != null || tab.sessionId != null)
                _AgentHandle(store: store, tab: tab),
              // O tique fica antes do x porque é a outra forma de acabar com
              // um painel — e a que fica com ele. Quem leu a resposta está
              // olhando pra este header; é daqui que ele diz "essa funcionou".
              Builder(
                builder: (ctx) => IconButton(
                  tooltip: tab.done
                      ? 'concluída — clique pra reabrir'
                      : 'marcar esta sessão como concluída',
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                  style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: () {
                    final box = ctx.findRenderObject() as RenderBox?;
                    markDone(
                      context,
                      store,
                      tab,
                      done: !tab.done,
                      // O confete sai do botão, não do canto da janela.
                      from: box?.localToGlobal(box.size.center(Offset.zero)),
                    );
                  },
                  icon: Icon(
                    tab.done ? Icons.task_alt : Icons.check_circle_outline,
                    color: tab.done ? Mx.green : Mx.fgDim,
                  ),
                ),
              ),
              // Sair do painel e encerrar a sessão são coisas diferentes, e este
              // é o gesto que se faz sem pensar -- então é o inofensivo. Matar
              // continua a um gesto de distância, e nos três lugares onde é
              // uma decisão: o X da linha na lateral, o menu do painel e ⌘⌫.
              IconButton(
                // A tecla vem do mapa: ela é editável, e um tooltip que
                // ensinasse ⌘⌫ a quem trocou por outra estaria mentindo.
                tooltip: [
                  'tirar do painel — a sessão continua na lateral',
                  if (store.keymap[MxAction.closePane].firstOrNull case final chord?)
                    '${chord.label} encerra a sessão',
                ].join('\n'),
                iconSize: 16,
                // Material pads a button out to a 48x48 touch target and
                // centres it in there — 11px of air on each side, which is
                // most of the way back to the inset we just removed. This is
                // a mouse-driven header; the 26px box is target enough.
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(width: 26, height: 26),
                style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                onPressed: () => store.dismiss(tab),
                icon: Icon(Icons.close, color: Mx.fgDim),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A digital da sessão, agora um endereço que se copia.
///
/// Uma sessão tem dois nomes e eles servem a coisas diferentes. O `--name` é
/// por onde outro agente fala com ela -- `ListAgents` e `SendMessage` só
/// conhecem nomes --, e é o que o clique copia, porque é o pedido comum:
/// abrir uma segunda sessão e mandá-la conversar com esta. O id da sessão é o
/// que retoma a conversa (`claude --resume`), e sai no ⌥ clique.
///
/// Como ícone parado ela dizia o id num tooltip, que é a metade menos usada
/// da informação e a única forma de tirá-la de lá era copiar do tooltip com
/// os olhos.
class _AgentHandle extends StatelessWidget {
  const _AgentHandle({required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  void _copy() {
    final name = tab.agentName;
    final id = tab.sessionId;
    // ⌥ pede o id; sem nome pra copiar, o id é o que há.
    final wantsId = HardwareKeyboard.instance.isAltPressed || name == null;
    final value = wantsId ? id : name;
    if (value == null) return;
    Clipboard.setData(ClipboardData(text: value));
    if (wantsId) {
      store.showBanner('id da sessão copiado: $value');
      return;
    }
    // Duas sessões na mesma pasta nascem com o mesmo nome -- é o padrão do
    // launch quando o painel não tem apelido --, e aí o nome sozinho não
    // endereça ninguém. Melhor dizer isso na hora de copiar do que deixar o
    // outro agente descobrir no erro.
    final twins = store.tabs.where((t) => t != tab && !t.exited && t.agentName == value).length;
    store.showBanner(
      twins == 0
          ? 'nome copiado: $value — outro agente fala com esta sessão por esse nome'
          : 'nome copiado: $value — cuidado: mais $twins sessão(ões) atendem por esse mesmo nome',
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = tab.agentName;
    final id = tab.sessionId;
    return IconButton(
      tooltip: [
        if (name != null) 'nome: $name  ·  clique pra copiar',
        if (id != null) 'sessão: $id  ·  ⌥ clique pra copiar',
      ].join('\n'),
      iconSize: 15,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: _copy,
      icon: Icon(Icons.fingerprint, color: Mx.fgFaint),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.status, this.size = 8});
  final ClaudeStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: status.color, shape: BoxShape.circle),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(color: color, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Shown in place of a pane when nothing is open. Doubles as the cheat sheet.
class EmptyPane extends StatelessWidget {
  // Deliberately not const: a const instance is canonicalised, so the element
  // tree would reuse it verbatim across a theme change and this pane would go
  // on painting the old palette.
  // ignore: prefer_const_constructors_in_immutables
  EmptyPane({super.key, this.store});

  /// Só pra contar o que ficou rodando na lateral: desde que o X do header
  /// apenas tira do painel, esta tela vazia não quer mais dizer que não há
  /// nada acontecendo.
  final AppStore? store;

  /// O que a cola ensina, na ordem em que se aprende o app.
  ///
  /// Ações e não teclas: as teclas são escolhidas nas configurações agora, e
  /// uma cola escrita à mão passaria a ensinar a combinação errada no dia em
  /// que alguém trocasse a dela. Sem store — que é como os testes montam esta
  /// tela — ficam os padrões, que é o que aquela janela teria mesmo.
  static const _cheatSheet = [
    MxAction.newClaude,
    MxAction.newShell,
    MxAction.newTask,
    MxAction.nextPane,
    MxAction.nextSession,
    MxAction.closePane,
    MxAction.settings,
  ];

  List<(String, String)> get _keys => [
    for (final action in _cheatSheet)
      if ((store?.keymap[action] ?? action.defaults) case final chords when chords.isNotEmpty)
        (chords.map((c) => c.label).join('  '), action.label),
    // Fixo, e por isso escrito: são nove teclas, não uma escolha.
    ('⌘1…9', 'ir pra enésima sessão'),
  ];

  String get _headline {
    final live = store?.tabs.where((t) => !t.exited).length ?? 0;
    if (live == 0) return 'nenhum painel aberto';
    if (live == 1) return '1 sessão rodando na lateral — clique nela pra trazer de volta';
    return '$live sessões rodando na lateral — clique numa pra trazer de volta';
  }

  @override
  Widget build(BuildContext context) {
    return MxPanel(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.grid_view_rounded, size: 30, color: Mx.fgFaint),
            const SizedBox(height: 14),
            Text(_headline, style: TextStyle(color: Mx.fgDim, fontSize: 13)),
            const SizedBox(height: 8),
            // A tela se divide por arraste e só por arraste, então é aqui que
            // isso é dito: sem um atalho pra listar, era o único gesto do app
            // que não aparecia em lugar nenhum.
            SizedBox(
              width: 330,
              child: Text(
                'arraste uma sessão da lateral pra cá — pela borda de um painel, '
                'ela divide a tela; pelo meio, toma o lugar dele',
                textAlign: TextAlign.center,
                style: TextStyle(color: Mx.fgFaint, fontSize: 11.5, height: 1.45),
              ),
            ),
            const SizedBox(height: 22),
            for (final (keys, what) in _keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      // Larga o bastante pras duas combinações de uma ação que
                      // tem duas — ⌃⇥ e ⌥⌘↓ são a mesma linha.
                      width: 104,
                      child: Text(
                        keys,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontFamily: Mx.mono, fontSize: 11.5, color: Mx.fg),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 210,
                      child: Text(what, style: TextStyle(fontSize: 11.5, color: Mx.fgFaint)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The "and then" a panel is carrying.
///
/// A queue is invisible by nature — it is a thing that will happen, not a
/// thing that is happening — so it gets a mark of its own in both places a
/// panel appears. The tooltip is the whole queue, because "3 passos" without
/// them is a promise you cannot check.
class FollowUpMark extends StatelessWidget {
  const FollowUpMark({super.key, required this.tab});
  final MxTab tab;

  @override
  Widget build(BuildContext context) {
    final steps = tab.followUps;
    if (steps.isEmpty) return const SizedBox.shrink();
    return Tooltip(
      message: [
        for (var i = 0; i < steps.length; i++)
          '${i + 1}. ${steps[i].kind.label}'
              '${steps[i].text.isEmpty ? '' : ': ${_clip(steps[i].text)}'}',
      ].join('\n'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.playlist_play, size: 15, color: Mx.purple),
          if (steps.length > 1) ...[
            const SizedBox(width: 2),
            Text(
              '${steps.length}',
              style: TextStyle(fontFamily: Mx.mono, fontSize: 10.5, color: Mx.purple),
            ),
          ],
        ],
      ),
    );
  }

  static String _clip(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 60 ? one : '${one.substring(0, 60)}…';
  }
}
