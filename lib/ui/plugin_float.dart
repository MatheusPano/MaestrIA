import 'package:flutter/material.dart';

import '../services/plugin_floats.dart';
import '../services/plugins.dart';
import '../services/store.dart';
import '../theme.dart';
import 'plugin_pane.dart';
import 'plugin_rfw.dart';

/// A camada dos flutuantes de plugin (`float.show`), por cima da janela
/// inteira menos a barra de status: a lateral e os painéis.
///
/// Um [Stack] sem fundo: onde não há flutuante o clique atravessa pro que está
/// embaixo, então a camada pode cobrir tudo sem roubar nada.
class PluginFloatLayer extends StatelessWidget {
  const PluginFloatLayer({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store.floats,
      builder: (context, _) {
        // Um plugin que caiu não atende mais o clique: o flutuante dele sai
        // da tela até o processo subir de novo e mandar outro.
        final shown = [
          for (final f in store.floats.shown)
            if (store.plugins.byId(f.pluginId) case final p?
                when p.state != PluginState.crashed && p.state != PluginState.disabled)
              f,
        ];
        if (shown.isEmpty) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (context, box) => Stack(
            children: [
              for (final f in shown)
                _Float(key: ValueKey(f.key), store: store, float: f, bounds: box.biggest),
            ],
          ),
        );
      },
    );
  }
}

class _Float extends StatefulWidget {
  const _Float({super.key, required this.store, required this.float, required this.bounds});

  final AppStore store;
  final PluginFloat float;
  final Size bounds;

  @override
  State<_Float> createState() => _FloatState();
}

class _FloatState extends State<_Float> {
  /// O canto de cima à esquerda enquanto você arrasta. Null parado: aí quem
  /// diz onde ele fica é o lugar guardado.
  Offset? _drag;

  /// A borda que ele guarda da janela.
  static const _margin = Mx.gap;

  /// Até onde da borda ele gruda nela.
  static const _snap = 28.0;

  PluginFloat get _f => widget.float;
  Size get _size => Size(_f.width, _f.height);

  /// O canto de cima à esquerda que [spot] quer dizer nesta janela, sem sair
  /// dela.
  Offset _place(FloatSpot spot) {
    final b = widget.bounds;
    final left = spot.corner.right ? b.width - _size.width - spot.dx : spot.dx;
    final top = spot.corner.bottom ? b.height - _size.height - spot.dy : spot.dy;
    return _clamp(Offset(left, top));
  }

  Offset _clamp(Offset o) {
    final b = widget.bounds;
    final maxX = (b.width - _size.width - _margin).clamp(_margin, double.infinity);
    final maxY = (b.height - _size.height - _margin).clamp(_margin, double.infinity);
    return Offset(o.dx.clamp(_margin, maxX), o.dy.clamp(_margin, maxY));
  }

  /// O lugar guardado de um canto de cima à esquerda: o canto da janela mais
  /// perto do meio dele, e a distância até as bordas daquele canto -- que
  /// vira a da margem quando ficou perto o bastante pra grudar.
  FloatSpot _spotAt(Offset o) {
    final b = widget.bounds;
    final center = o + _size.center(Offset.zero);
    final corner = FloatCorner.of(right: center.dx > b.width / 2, bottom: center.dy > b.height / 2);
    var dx = corner.right ? b.width - _size.width - o.dx : o.dx;
    var dy = corner.bottom ? b.height - _size.height - o.dy : o.dy;
    if (dx < _margin + _snap) dx = _margin;
    if (dy < _margin + _snap) dy = _margin;
    return (corner: corner, dx: dx, dy: dy);
  }

  FloatSpot get _spot =>
      widget.store.floats.spotOf(_f) ??
      (corner: _f.start, dx: _margin, dy: _margin);

  @override
  Widget build(BuildContext context) {
    final at = _drag ?? _place(_spot);
    final dragging = _drag != null;
    return AnimatedPositioned(
      // Solto, ele desliza pro lugar em que grudou; no arraste, segue o mouse
      // sem atraso.
      duration: dragging ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      left: at.dx,
      top: at.dy,
      width: _size.width,
      height: _size.height,
      child: MouseRegion(
        cursor: dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
        child: GestureDetector(
          // Pan, e não um Draggable: um toque parado continua sendo dos botões
          // de dentro -- quem se mexe além da tolerância do gesto é arraste.
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => setState(() => _drag = at),
          onPanUpdate: (d) => setState(() => _drag = _clamp((_drag ?? at) + d.delta)),
          onPanEnd: (_) => _drop(),
          onPanCancel: _drop,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: Mx.bg,
              borderRadius: BorderRadius.circular(Mx.radius),
              border: Border.all(color: dragging ? Mx.accent : Mx.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dragging ? 0.38 : 0.26),
                  blurRadius: dragging ? 22 : 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Mx.radius - 1),
              child: Material(
                type: MaterialType.transparency,
                child: _f.view.rfwLibrary != null
                    ? PluginRfw(store: widget.store, tab: _f.tab)
                    : PluginPane(store: widget.store, tab: _f.tab, bare: true),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _drop() {
    final at = _drag;
    if (at == null) return;
    setState(() => _drag = null);
    widget.store.floats.move(_f, _spotAt(at));
  }
}
