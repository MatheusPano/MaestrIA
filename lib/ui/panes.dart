import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/layout.dart';
import '../services/store.dart';
import '../theme.dart';
import 'terminal_pane.dart';

/// Onde o mouse está, reconstruído do que o [DragTarget] entrega.
///
/// O `DragTargetDetails.offset` não é o ponteiro: é o canto do cartão que voa
/// junto com ele. E esse canto sai do ponto onde você pegou a linha, então
/// numa lateral de 350px de largura ele erra o lado do painel por meia tela --
/// pegar a linha pela direita e soltar no meio de um painel cairia na borda
/// esquerda dele. A linha arrastada diz aqui por onde foi pega; a soma dos
/// dois é o ponteiro de volta, sem defasagem de um evento.
///
/// Uma variável só porque só existe um arraste por vez, e um só lugar que
/// levanta uma sessão: a linha da lateral.
abstract final class DragCursor {
  static Offset grab = Offset.zero;

  static Offset pointer(Offset corner) => corner + grab;
}

/// A região principal: a árvore de painéis, desenhada.
///
/// Um painel é uma posição, e a árvore é o desenho dela — ver `layout.dart`.
/// Aqui só tem o que a tela precisa saber: onde cortar, onde soltar, e qual
/// deles o teclado está escutando.
class PaneArea extends StatelessWidget {
  const PaneArea({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final root = store.panes;
    if (root == null) return _EmptyDrop(store: store);
    return _Node(store: store, node: root);
  }
}

class _Node extends StatelessWidget {
  const _Node({required this.store, required this.node});

  final AppStore store;
  final PaneNode node;

  @override
  Widget build(BuildContext context) {
    if (node case final PaneLeaf leaf) {
      final tab = store.tabById(leaf.tabId);
      // A sessão morreu e saiu da lista antes da árvore ser podada: um quadro
      // vazio por um frame é melhor que uma exceção no meio do layout.
      if (tab == null) return const SizedBox.shrink();
      return _PaneSlot(key: ValueKey(tab.id), store: store, tab: tab);
    }

    final split = node as PaneSplit;
    final row = split.axis == PaneAxis.row;
    return LayoutBuilder(
      builder: (context, box) {
        // As alças ficam fora da conta das frações: elas medem o mesmo em
        // qualquer janela, então o que se reparte é o que sobra delas.
        final total = (row ? box.maxWidth : box.maxHeight) - Mx.gap * (split.children.length - 1);
        final children = <Widget>[];
        for (var i = 0; i < split.children.length; i++) {
          if (i > 0) {
            children.add(_Grip(store: store, split: split, gutter: i - 1, total: total));
          }
          children.add(
            Expanded(
              // Flex é inteiro; as frações viram milésimos, que é fino o
              // bastante pra uma arrastada de um pixel aparecer.
              flex: math.max(1, (split.weights[i] * 10000).round()),
              child: _Node(store: store, node: split.children[i]),
            ),
          );
        }
        return row ? Row(children: children) : Column(children: children);
      },
    );
  }
}

/// Um painel, e as quatro bordas por onde ele se divide.
class _PaneSlot extends StatefulWidget {
  const _PaneSlot({super.key, required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  @override
  State<_PaneSlot> createState() => _PaneSlotState();
}

class _PaneSlotState extends State<_PaneSlot> {
  /// O lado onde o painel que está no ar vai cair, enquanto ele está no ar.
  DropSide? _side;

  /// O miolo que vale como "trocar", medido do centro pra fora: uma fração do
  /// painel, com teto em pixels pra que um painel enorme não vire um alvo de
  /// troca enorme.
  ///
  /// Fora dele quem decide é a direção, não a distância até a borda: soltar à
  /// direita do meio divide pela direita, ainda que a borda esteja longe. Era
  /// uma faixa de borda com teto de 120px, e num painel de 1400px isso deixava
  /// 90% da largura dizendo "trocar" -- inclusive um palmo depois do meio.
  static const _core = 0.15;
  static const _maxCore = 160.0;

  DropSide _sideAt(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return DropSide.center;
    final p = box.globalToLocal(global);
    final size = box.size;
    if (size.isEmpty) return DropSide.center;
    final dx = p.dx - size.width / 2;
    final dy = p.dy - size.height / 2;
    if (dx.abs() < math.min(size.width * _core, _maxCore) &&
        dy.abs() < math.min(size.height * _core, _maxCore)) {
      return DropSide.center;
    }
    // As diagonais do painel repartem o resto. Medidas em metades e não em
    // pixels, senão num painel baixo e largo as diagonais deitariam e quase
    // tudo cairia no topo ou no rodapé.
    final DropSide side;
    if ((dx / size.width).abs() >= (dy / size.height).abs()) {
      side = dx < 0 ? DropSide.left : DropSide.right;
    } else {
      side = dy < 0 ? DropSide.top : DropSide.bottom;
    }
    // Um painel que não tem como caber em dois não oferece a divisão: a marca
    // some da borda e o drop vira o que ainda faz sentido ali, que é trocar.
    // Melhor não oferecer do que oferecer e recusar depois de solto.
    final room = side.axis == PaneAxis.row ? size.width : size.height;
    return room / 2 < Panes.minFor(side.axis) ? DropSide.center : side;
  }

  void _track(Offset corner) {
    final side = _sideAt(DragCursor.pointer(corner));
    if (side != _side) setState(() => _side = side);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return DragTarget<MxTab>(
      onWillAcceptWithDetails: (d) {
        _track(d.offset);
        return true;
      },
      onMove: (d) => _track(d.offset),
      onLeave: (_) {
        if (_side != null) setState(() => _side = null);
      },
      onAcceptWithDetails: (d) {
        final side = _side ?? DropSide.center;
        setState(() => _side = null);
        store.dropTab(d.data, target: widget.tab, side: side);
      },
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          TerminalPane(
            store: store,
            tab: widget.tab,
            // Pelo [AppStore.focusedTab], não pelo id cru: com um foco que
            // aponta pra uma sessão que já saiu da tela, nenhum painel
            // acenderia o anel e o teclado pareceria não estar em lugar nenhum.
            focused: store.focusedTab?.id == widget.tab.id,
            // Um painel sozinho não precisa dizer que está em foco: não há
            // outro pra ele estar em foco em vez de.
            showFocus: store.paneCount > 1,
            onFocus: () => store.focusPane(widget.tab),
          ),
          if (_side case final side?) IgnorePointer(child: _DropHint(side: side)),
        ],
      ),
    );
  }
}

/// O retângulo que diz onde a sessão vai parar se você soltar agora.
///
/// É o próprio lugar futuro do painel — metade de cima, metade da direita, o
/// painel inteiro — e não uma seta apontando pra ele. Animado porque o lado
/// muda enquanto o mouse anda: sem isso a marca pisca de um lado pro outro.
class _DropHint extends StatelessWidget {
  const _DropHint({required this.side});

  final DropSide side;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        final rect = switch (side) {
          DropSide.left => Rect.fromLTWH(0, 0, w / 2, h),
          DropSide.right => Rect.fromLTWH(w / 2, 0, w / 2, h),
          DropSide.top => Rect.fromLTWH(0, 0, w, h / 2),
          DropSide.bottom => Rect.fromLTWH(0, h / 2, w, h / 2),
          DropSide.center => Rect.fromLTWH(0, 0, w, h),
        };
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Mx.accent.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(Mx.radius),
                  border: Border.fromBorderSide(
                    BorderSide(color: Mx.accent.withValues(alpha: 0.8), width: 1.6),
                  ),
                ),
                child: Center(
                  child: DropLabel(text: side == DropSide.center ? 'trocar' : 'dividir'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A palavra dentro da marca. Duas coisas cabem no mesmo gesto — cortar o
/// painel ou tomar o lugar dele — e a diferença entre elas é o que a marca
/// sozinha não diz.
class DropLabel extends StatelessWidget {
  const DropLabel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Mx.bgActive,
        borderRadius: BorderRadius.circular(999),
        border: Border.fromBorderSide(BorderSide(color: Mx.border)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: Mx.fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A tela limpa, que também recebe drop: com nada aberto, qualquer canto dela
/// é o primeiro painel.
class _EmptyDrop extends StatefulWidget {
  const _EmptyDrop({required this.store});

  final AppStore store;

  @override
  State<_EmptyDrop> createState() => _EmptyDropState();
}

class _EmptyDropState extends State<_EmptyDrop> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<MxTab>(
      onWillAcceptWithDetails: (_) {
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) => setState(() => _over = false),
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.store.select(d.data);
      },
      builder: (context, _, _) => Stack(
        fit: StackFit.expand,
        children: [
          EmptyPane(store: widget.store),
          if (_over) const IgnorePointer(child: _DropHint(side: DropSide.center)),
        ],
      ),
    );
  }
}

/// A alça entre dois painéis.
///
/// Mede exatamente [Mx.gap], o vão que já existia entre os cartões: pegar a
/// divisa não custa um pixel de layout. Duplo clique devolve os dois vizinhos
/// ao meio.
class _Grip extends StatefulWidget {
  const _Grip({
    required this.store,
    required this.split,
    required this.gutter,
    required this.total,
  });

  final AppStore store;
  final PaneSplit split;
  final int gutter;
  final double total;

  @override
  State<_Grip> createState() => _GripState();
}

class _GripState extends State<_Grip> {
  bool _hover = false;
  bool _dragging = false;

  bool get _row => widget.split.axis == PaneAxis.row;

  void _drag(double delta) =>
      widget.store.resizeSplit(widget.split, widget.gutter, delta, widget.total);

  void _even() {
    final a = widget.split.weights[widget.gutter];
    final b = widget.split.weights[widget.gutter + 1];
    // O mesmo caminho da arrastada, com o delta que empata os dois: assim o
    // duplo clique respeita o mesmo mínimo que a mão respeita.
    _drag((b - a) / 2 * widget.total);
  }

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _dragging;
    return MouseRegion(
      cursor: _row ? SystemMouseCursors.resizeLeftRight : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _row ? (_) => setState(() => _dragging = true) : null,
        onHorizontalDragEnd: _row ? (_) => setState(() => _dragging = false) : null,
        onHorizontalDragCancel: _row ? () => setState(() => _dragging = false) : null,
        onHorizontalDragUpdate: _row ? (d) => _drag(d.delta.dx) : null,
        onVerticalDragStart: _row ? null : (_) => setState(() => _dragging = true),
        onVerticalDragEnd: _row ? null : (_) => setState(() => _dragging = false),
        onVerticalDragCancel: _row ? null : () => setState(() => _dragging = false),
        onVerticalDragUpdate: _row ? null : (d) => _drag(d.delta.dy),
        onDoubleTap: _even,
        child: SizedBox(
          width: _row ? Mx.gap : null,
          height: _row ? null : Mx.gap,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: _row ? 3 : (lit ? 46 : 0),
              height: _row ? (lit ? 46 : 0) : 3,
              decoration: BoxDecoration(
                color: _dragging ? Mx.accent : Mx.fgFaint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
