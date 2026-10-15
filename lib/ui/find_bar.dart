import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/shortcuts.dart';
import '../services/store.dart';
import '../services/terminal_find.dart';
import '../theme.dart';

/// O endereço da busca de cada painel, pra quem está fora dele.
///
/// O ⌘F que chega com o foco no terminal é resolvido lá dentro; o que chega
/// com o foco em outro lugar (a busca da lateral, um diálogo que acabou de
/// fechar) sobe pro mapa global, que só sabe qual é o painel em foco. Cada
/// superfície de terminal se inscreve aqui com o id do painel que está
/// mostrando -- o mesmo arranjo do [SidebarSearch], com um campo por painel.
class TerminalFind {
  const TerminalFind._();

  static final _open = <String, VoidCallback>{};

  static void register(String tabId, VoidCallback open) => _open[tabId] = open;

  /// Só tira se ainda for o mesmo: um painel que trocou de lugar na grade se
  /// inscreve pelo novo antes de o velho sair.
  static void unregister(String tabId, VoidCallback open) {
    if (_open[tabId] == open) _open.remove(tabId);
  }

  /// Abre a busca em [tab], e diz se havia um terminal na tela pra isso.
  static bool open(MxTab tab) {
    final open = _open[tab.id];
    open?.call();
    return open != null;
  }
}

/// O que se achou num painel, e qual dos achados é o da vez.
///
/// Os destaques são do xterm ([TerminalController.highlight]) e ancorados nas
/// linhas, não nas posições: o Claude continua escrevendo com a busca aberta, e
/// um destaque preso à linha 120 estaria em cima de outra coisa assim que o
/// scrollback rolasse.
class FindSession extends ChangeNotifier {
  FindSession(this.terminal, this.controller);

  final Terminal terminal;
  final TerminalController controller;

  String _query = '';
  String get query => _query;

  List<TermHit> _hits = const [];
  List<TermHit> get hits => _hits;

  /// O achado da vez, ou -1 quando não há nenhum.
  int _index = -1;
  int get index => _index;

  TermHit? get current => _index < 0 ? null : _hits[_index];

  final _marks = <TerminalHighlight>[];

  /// Busca [query] de novo, do zero.
  ///
  /// O da vez é o último que começa até [nearLine]: quem abre a busca está no
  /// fim do painel, lendo o que acabou de sair, e o achado mais recente acima
  /// do que está na tela é o que ele quer -- não o primeiro do scrollback.
  void search(String query, {required int nearLine}) {
    _query = query;
    _hits = findInTerminal(terminal, query);
    _index = _hits.lastIndexWhere((h) => h.from.y <= nearLine);
    if (_index < 0 && _hits.isNotEmpty) _index = 0;
    _paint();
  }

  /// A mesma busca sobre o que o painel escreveu desde a última, sem trocar o
  /// achado da vez de lugar: ele é o que a pessoa está lendo.
  void refresh() {
    if (_query.isEmpty) return;
    // Pela âncora do destaque, e não pela posição guardada em [current]: as
    // linhas que saem pelo topo do scrollback deslocam todo mundo pra cima, e
    // a âncora é a única que acompanha.
    final mark = _index < 0 ? null : _marks[_index].p1;
    final was = mark != null && mark.attached ? mark.offset : null;
    _hits = findInTerminal(terminal, _query);
    if (_hits.isEmpty) {
      _index = -1;
    } else if (was == null) {
      _index = _hits.length - 1;
    } else {
      // O mesmo achado, se ainda existir; senão o primeiro depois dele.
      final after = _hits.indexWhere((h) => !_before(h.from, was));
      _index = after < 0 ? _hits.length - 1 : after;
    }
    _paint();
  }

  /// Anda [by] achados, dando a volta nas pontas.
  void step(int by) {
    if (_hits.isEmpty) return;
    _index = (_index + by) % _hits.length;
    _paint();
  }

  void clear() {
    _query = '';
    _hits = const [];
    _index = -1;
    _paint();
  }

  @override
  void dispose() {
    _unpaint();
    super.dispose();
  }

  static bool _before(CellOffset a, CellOffset b) => a.y < b.y || (a.y == b.y && a.x < b.x);

  void _unpaint() {
    for (final m in _marks) {
      m.dispose();
    }
    _marks.clear();
  }

  void _paint() {
    _unpaint();
    final lines = terminal.buffer.lines;
    // Um destaque por achado, na mesma ordem: [refresh] lê o da vez por
    // `_marks[_index]`.
    for (var i = 0; i < _hits.length; i++) {
      final hit = _hits[i];
      _marks.add(
        controller.highlight(
          p1: lines[hit.from.y].createAnchor(hit.from.x),
          p2: lines[hit.to.y].createAnchor(hit.to.x),
          // Por cima do texto, que é como o xterm pinta destaque: daí a
          // transparência, senão a cor tampava a palavra achada.
          color: Mx.yellow.withValues(alpha: i == _index ? 0.62 : 0.24),
        ),
      );
    }
    notifyListeners();
  }
}

/// A barra de busca, no canto de cima do painel.
///
/// Enter sobe pro achado anterior e ⇧Enter desce: a busca abre no fim do
/// painel, e o que se procura no terminal é quase sempre algo que já passou.
/// Esc fecha e devolve o teclado ao terminal.
class FindBar extends StatefulWidget {
  const FindBar({
    super.key,
    required this.session,
    required this.controller,
    required this.focusNode,
    required this.onQuery,
    required this.onStep,
    required this.onClose,
  });

  final FindSession session;

  /// O texto e o foco vêm de fora porque é o painel quem os pede de volta num
  /// segundo ⌘F: o campo volta ao foco com o que já estava escrito
  /// selecionado, pra trocar a busca digitando por cima.
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onQuery;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  State<FindBar> createState() => _FindBarState();
}

class _FindBarState extends State<FindBar> {
  /// O que o campo escreveu e ainda não foi buscado. Cem milissegundos porque
  /// um scrollback cheio são milhares de linhas, e buscar a cada letra de
  /// `function` seria buscar sete vezes o que ninguém vai ler.
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 100), () => widget.onQuery(value));
  }

  /// Enter com a busca ainda pendente busca antes de andar: senão ele andaria
  /// sobre os achados da palavra de três letras atrás.
  void _step(int by) {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      widget.onQuery(widget.controller.text);
      return;
    }
    widget.onStep(by);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final count = session.hits.length;
        final none = session.query.isNotEmpty && count == 0;
        return Container(
          height: 34,
          width: 300,
          padding: const EdgeInsets.only(left: 10, right: 4),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: none ? Mx.red : Mx.border),
            boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 14, color: Mx.fgFaint),
              const SizedBox(width: 6),
              Expanded(
                child: CallbackShortcuts(
                  // Em volta do campo, e não do painel: é com o cursor nele
                  // que o Enter quer dizer "próximo" e não "mande o prompt".
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): () => _step(-1),
                    const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _step(1),
                    const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
                  },
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    onChanged: _changed,
                    cursorColor: Mx.accent,
                    cursorWidth: 1.5,
                    style: TextStyle(fontSize: 12, color: Mx.fg),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: 'Buscar no painel',
                      hintStyle: TextStyle(fontSize: 12, color: Mx.fgFaint),
                    ),
                  ),
                ),
              ),
              if (session.query.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    count == 0
                        ? 'Nenhum'
                        : '${session.index + 1} de $count${count >= 1000 ? '+' : ''}',
                    style: TextStyle(
                      fontSize: 11,
                      color: none ? Mx.red : Mx.fgFaint,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              _FindButton(
                icon: Icons.keyboard_arrow_up_rounded,
                tooltip: 'Anterior  ⏎',
                onTap: count == 0 ? null : () => _step(-1),
              ),
              _FindButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: MxChord.linux ? 'Próximo  Shift+Enter' : 'Próximo  ⇧⏎',
                onTap: count == 0 ? null : () => _step(1),
              ),
              _FindButton(
                icon: Icons.close_rounded,
                tooltip: MxChord.linux ? 'Fechar  Esc' : 'Fechar  ⎋',
                onTap: widget.onClose,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Um alvo de 24px na barra: o mesmo desenho do botão de dentro da busca da
/// lateral, que é a outra busca do app.
class _FindButton extends StatefulWidget {
  const _FindButton({required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;

  /// Null apaga o botão: sem achados não há pra onde andar.
  final VoidCallback? onTap;

  @override
  State<_FindButton> createState() => _FindButtonState();
}

class _FindButtonState extends State<_FindButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _hover && enabled ? Mx.border : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: !enabled ? Mx.fgFaint.withValues(alpha: 0.4) : (_hover ? Mx.fg : Mx.fgDim),
            ),
          ),
        ),
      ),
    );
  }
}
