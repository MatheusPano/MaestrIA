import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:rfw/formats.dart' show parseLibraryFile;
import 'package:rfw/rfw.dart';

import '../services/plugins.dart';
import '../services/store.dart';
import '../theme.dart';
import 'menus.dart';
import 'plugin_pane.dart';

/// A janela que o plugin monta ele mesmo: uma árvore de widgets em texto (o
/// formato do Remote Flutter Widgets) que a Maestria desenha com o Flutter de
/// verdade -- o mesmo motor, o mesmo tema, os mesmos atalhos.
///
/// É o outro jeito de um plugin ter janela, ao lado dos blocos. Com os blocos
/// a Maestria tem as peças prontas (lista, botão, console) e o plugin escolhe
/// entre elas; aqui a Maestria só tem as primitivas (`Row`, `Column`,
/// `Container`, `Text`…) e o plugin compõe o que quiser com elas. Um visual
/// novo num plugin não pede nada do app.
///
/// Três coisas vêm do plugin, pelo `rfw` de `view.open`/`view.update`/
/// `sidebar.update`: a biblioteca (o texto, lido só quando muda), o nome do
/// widget de cima (`root`) e os dados (`data`), que trocam sem reler nada. A
/// janela põe `data.theme` com as cores do tema em vigor, e os `event "x" {…}`
/// do texto voltam pro plugin como `view.action` com `action: "x"`.
class PluginRfw extends StatefulWidget {
  const PluginRfw({super.key, required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  @override
  State<PluginRfw> createState() => _PluginRfwState();
}

class _PluginRfwState extends State<PluginRfw> {
  static const _core = LibraryName(['core', 'widgets']);
  static const _material = LibraryName(['core', 'material']);
  static const _maestria = LibraryName(['maestria']);
  static const _plugin = LibraryName(['plugin']);

  final Runtime _runtime = Runtime();
  final DynamicContent _content = DynamicContent();
  String? _library;
  String? _error;
  int _dataRevision = -1;

  PluginView get _view => widget.tab.view!;

  @override
  void initState() {
    super.initState();
    _runtime
      ..update(_core, createCoreWidgets())
      ..update(_material, createMaterialWidgets())
      ..update(_maestria, _localWidgets());
    _theme();
    Mx.chrome.addListener(_theme);
  }

  @override
  void dispose() {
    Mx.chrome.removeListener(_theme);
    _runtime.dispose();
    super.dispose();
  }

  /// As cores do tema em `data.theme`, como inteiros 0xAARRGGBB -- que é como
  /// o rfw lê uma cor.
  void _theme() {
    final p = Mx.palette;
    int c(Color x) => x.toARGB32();
    _content.update('theme', <String, Object>{
      'dark': p.dark,
      'canvas': c(p.canvas),
      'bg': c(p.bg),
      'sidebar': c(p.bgSidebar),
      'hover': c(p.bgHover),
      'active': c(p.bgActive),
      'border': c(p.border),
      'fg': c(p.fg),
      'dim': c(p.fgDim),
      'faint': c(p.fgFaint),
      'accent': c(p.accent),
      'onAccent': ThemeData.estimateBrightnessForColor(p.accent) == Brightness.dark
          ? 0xFFFFFFFF
          : c(p.canvas),
      'green': c(p.green),
      'yellow': c(p.yellow),
      'red': c(p.red),
      'purple': c(p.purple),
      'blue': c(p.ansi.blue),
      'cyan': c(p.ansi.cyan),
      'magenta': c(p.ansi.magenta),
      'mono': Mx.mono,
    });
  }

  /// Lê a biblioteca quando o texto mudou, e os dados quando o plugin mandou
  /// outros. Um erro no texto aparece na janela: é o autor do plugin quem
  /// precisa vê-lo.
  void _sync() {
    final text = _view.rfwLibrary;
    if (text != null && text != _library) {
      _library = text;
      try {
        _runtime.update(_plugin, parseLibraryFile(text));
        _error = null;
      } catch (e) {
        _error = '$e';
      }
    }
    if (_view.rfwRevision != _dataRevision) {
      _dataRevision = _view.rfwRevision;
      for (final e in _view.rfwData.entries) {
        if (e.key == 'theme') continue;
        _content.update(e.key, e.value as Object);
      }
    }
  }

  void _event(String name, DynamicMap arguments) {
    widget.store.pluginViewAction(widget.tab, name, _plain(arguments) as Map<String, dynamic>);
  }

  /// O que o rfw entrega (mapas e listas dele) em json comum pro plugin.
  static Object? _plain(Object? v) => switch (v) {
    final Map m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
    final List l => [for (final x in l) _plain(x)],
    _ => v,
  };

  @override
  Widget build(BuildContext context) {
    _sync();
    if (_error case final e?) {
      return Padding(
        padding: const EdgeInsets.all(14),
        child: SelectableText(
          'a interface do plugin não leu:\n$e',
          style: TextStyle(fontFamily: Mx.mono, fontSize: 11.5, color: Mx.red, height: 1.45),
        ),
      );
    }
    if (_library == null) return const SizedBox.shrink();
    return DefaultTextStyle.merge(
      style: TextStyle(color: Mx.fg, fontSize: 13),
      child: RemoteWidget(
        runtime: _runtime,
        data: _content,
        widget: FullyQualifiedWidgetName(_plugin, _view.rfwRoot),
        onEvent: _event,
      ),
    );
  }

  // --- as peças da Maestria -----------------------------------------------------
  //
  // O que as primitivas não fazem: o desenho do app (os ícones, um svg
  // colorido), o hover e o menu de botão direito, e os botões de ícone. Ficam
  // em `import maestria;`.

  LocalWidgetLibrary _localWidgets() {
    final dir = widget.store.plugins.byId(_view.pluginId)?.dir;
    return LocalWidgetLibrary(<String, LocalWidgetBuilder>{
      // Svg(svg: "<svg…>", width: 26.0, height: 26.0): o desenho com as cores dele.
      'Svg': (context, source) {
        final svg = source.v<String>(['svg']);
        if (svg == null) return const SizedBox.shrink();
        return SvgPicture.string(
          svg,
          width: source.v<double>(['width']),
          height: source.v<double>(['height']),
          excludeFromSemantics: true,
        );
      },
      // Glyph(icon: "stop", size: 16.0, color: …): um ícone do app, ou um
      // `.svg` da pasta do plugin, pintado de uma cor.
      'Glyph': (context, source) => PluginGlyph(
        icon: source.v<String>(['icon']),
        dir: dir,
        size: source.v<double>(['size']) ?? 16,
        color: ArgumentDecoders.color(source, ['color']),
      ),
      // IconButton(icon: "trash", tooltip: "remover", onPressed: event …).
      'IconButton': (context, source) {
        final onPressed = source.v<bool>(['disabled']) == true
            ? null
            : source.voidHandler(['onPressed']);
        final color = ArgumentDecoders.color(source, ['color']) ?? Mx.fgDim;
        return IconButton(
          tooltip: source.v<String>(['tooltip']),
          iconSize: source.v<double>(['size']) ?? 16,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(
            width: source.v<double>(['extent']) ?? 26,
            height: source.v<double>(['extent']) ?? 26,
          ),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: onPressed,
          icon: Icon(
            pluginIcon(source.v<String>(['icon'])) ?? Icons.circle_outlined,
            color: onPressed == null ? color.withValues(alpha: 0.4) : color,
          ),
        );
      },
      'Tooltip': (context, source) =>
          Tooltip(message: source.v<String>(['message']) ?? '', child: source.child(['child'])),
      // Pressable(child, onTap, onDoubleTap, color, hoverColor, radius,
      // padding, menu: [{ label, icon, action, red, disabled } | { divider:
      // true }], onMenu: event "…" {}): uma área que acende com o mouse em
      // cima, clica e abre o menu de botão direito. A escolha do menu vai no
      // onMenu com `action` a mais nos argumentos.
      'Pressable': (context, source) => _Pressable(source: source),
      // MenuButton(icon: "more", tooltip, menu: […], onMenu: event "…" {}):
      // o botão de ícone que abre o menu embaixo dele -- o "…" de um topo.
      'MenuButton': (context, source) => _Pressable(source: source, button: true),
      // Draggable(payload: "id", targets: ["a", "b"], width: 280.0, child,
      // feedback?, disabled?): o que dá pra arrastar -- o cartão de um quadro.
      // `payload` é o que o DropTarget recebe; `targets`, os ids dos alvos que o
      // aceitam (sem ele, todos).
      'Draggable': (context, source) => _Drag(spec: _readDrag(source)),
      // DropTarget(id: "a", onDrop: event "…" {}, child, hint?, color?,
      // hoverColor?, radius?): onde soltar -- a coluna. O que cai vai no onDrop
      // com `payload` e `to` (o id) a mais nos argumentos.
      'DropTarget': (context, source) => _Drop(spec: _readDrop(source)),
    });
  }
}

/// Um item do menu de um `Pressable`/`MenuButton`, lido do `menu` do rfw.
typedef _MenuItem = ({
  String? action,
  String label,
  String? icon,
  bool red,
  bool disabled,
  List<({String action, String label, int color})> children,
});

/// Tudo que um `Pressable` (ou `MenuButton`) pediu, lido na hora do builder:
/// o rfw exige que a fonte seja lida ali, e não depois no build de um filho.
({
  VoidCallback? onTap,
  VoidCallback? onDoubleTap,
  Color? color,
  Color? hoverColor,
  double radius,
  EdgeInsetsGeometry? padding,
  Widget? child,
  List<_MenuItem> menu,
  void Function(DynamicMap)? onMenu,
  String? icon,
  String? tooltip,
  double size,
})
_read(DataSource s, {required bool button}) {
  final n = s.length(['menu']);
  return (
    onTap: s.voidHandler(['onTap']),
    onDoubleTap: s.voidHandler(['onDoubleTap']),
    color: ArgumentDecoders.color(s, ['color']),
    hoverColor: ArgumentDecoders.color(s, ['hoverColor']),
    radius: s.v<double>(['radius']) ?? 0,
    padding: ArgumentDecoders.edgeInsets(s, ['padding']),
    child: button ? null : s.optionalChild(['child']),
    menu: [
      for (var i = 0; i < n; i++)
        (
          action: s.v<bool>(['menu', i, 'divider']) == true
              ? null
              : s.v<String>(['menu', i, 'action']),
          label: s.v<String>(['menu', i, 'label']) ?? '',
          icon: s.v<String>(['menu', i, 'icon']),
          red: s.v<bool>(['menu', i, 'red']) == true,
          disabled: s.v<bool>(['menu', i, 'disabled']) == true,
          // Um submenu: `children: [{ label, action, color? }]` -- a paleta de cores.
          children: [
            for (var j = 0; j < s.length(['menu', i, 'children']); j++)
              (
                action: s.v<String>(['menu', i, 'children', j, 'action']) ?? '',
                label: s.v<String>(['menu', i, 'children', j, 'label']) ?? '',
                color: s.v<int>(['menu', i, 'children', j, 'color']) ?? 0,
              ),
          ],
        ),
    ],
    onMenu: s.handler<void Function(DynamicMap)>(
      ['onMenu'],
      (trigger) =>
          (extra) => trigger(extra),
    ),
    icon: s.v<String>(['icon']),
    tooltip: s.v<String>(['tooltip']),
    size: s.v<double>(['size']) ?? 16,
  );
}

class _Pressable extends StatefulWidget {
  _Pressable({required DataSource source, this.button = false})
    : spec = _read(source, button: button);

  final ({
    VoidCallback? onTap,
    VoidCallback? onDoubleTap,
    Color? color,
    Color? hoverColor,
    double radius,
    EdgeInsetsGeometry? padding,
    Widget? child,
    List<_MenuItem> menu,
    void Function(DynamicMap)? onMenu,
    String? icon,
    String? tooltip,
    double size,
  })
  spec;

  /// O `MenuButton`: um ícone, e o menu abre no clique, embaixo dele.
  final bool button;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _hover = false;

  Future<void> _menu(Offset at) async {
    final spec = widget.spec;
    final choice = await mxMenu<String>(
      context,
      at: at,
      items: [
        for (final m in spec.menu)
          if (m.action == null)
            mxDivider()
          else if (m.children.isNotEmpty)
            MxSubmenuItem(
              label: m.label,
              glyph: switch (pluginIcon(m.icon)) {
                final IconData icon => Icon(icon, size: 14, color: Mx.fgDim),
                _ => null,
              },
              items: () => [
                for (final c in m.children)
                  MxSubItem(
                    value: c.action,
                    label: c.label,
                    glyph: colorDot(c.color == 0 ? null : Color(c.color)),
                  ),
              ],
            )
          else
            mxItem(
              m.action!,
              label: m.label.isEmpty ? m.action! : m.label,
              enabled: !m.disabled,
              color: m.red ? Mx.red : null,
              glyph: switch (pluginIcon(m.icon)) {
                final IconData icon => Icon(icon, size: 14, color: m.red ? Mx.red : Mx.fgDim),
                _ => null,
              },
            ),
      ],
    );
    if (choice != null) spec.onMenu?.call(<String, Object?>{'action': choice});
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    if (widget.button) {
      return Builder(
        builder: (context) => IconButton(
          tooltip: spec.tooltip,
          iconSize: spec.size,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            _menu(box.localToGlobal(Offset(box.size.width - 200, box.size.height + 4)));
          },
          icon: Icon(
            pluginIcon(spec.icon) ?? Icons.more_horiz_rounded,
            color: spec.color ?? Mx.fgDim,
          ),
        ),
      );
    }
    return MouseRegion(
      cursor: spec.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: spec.onTap,
        onDoubleTap: spec.onDoubleTap,
        onSecondaryTapDown: spec.menu.isEmpty ? null : (d) => _menu(d.globalPosition),
        child: Container(
          padding: spec.padding,
          decoration: BoxDecoration(
            color: _hover && spec.hoverColor != null ? spec.hoverColor : spec.color,
            borderRadius: spec.radius > 0 ? BorderRadius.circular(spec.radius) : null,
          ),
          child: spec.child,
        ),
      ),
    );
  }
}

// --- arrastar e soltar ----------------------------------------------------------
//
// O rfw não tem arrastar: `Draggable` e `DropTarget` são da Maestria. O que é
// arrastado leva um texto (`payload`) e diz em quais alvos pode cair
// (`targets`); o alvo que aceita avisa o plugin com os dois, e o plugin decide o
// que isso quer dizer -- iniciar a tarefa, mover o arquivo. Enquanto alguma
// coisa está no ar, os alvos que a aceitam se acendem de leve, pra você ver onde
// ela pode ir; o que está embaixo do cursor se acende de vez.

/// O que está sendo arrastado agora: os alvos que aceitam (vazio é todos), ou
/// `null` com nada no ar.
final ValueNotifier<List<String>?> _dragging = ValueNotifier(null);

typedef _DragSpec = ({
  String payload,
  List<String> targets,
  double? width,
  bool disabled,
  Widget? child,
  Widget? feedback,
});

_DragSpec _readDrag(DataSource s) {
  final n = s.length(['targets']);
  return (
    payload: s.v<String>(['payload']) ?? '',
    targets: [
      for (var i = 0; i < n; i++) ?s.v<String>(['targets', i]),
    ],
    width: s.v<double>(['width']),
    disabled: s.v<bool>(['disabled']) == true,
    child: s.optionalChild(['child']),
    feedback: s.optionalChild(['feedback']),
  );
}

/// O que viaja com o arraste.
class _Payload {
  const _Payload(this.value, this.targets);
  final String value;
  final List<String> targets;
  bool fits(String id) => targets.isEmpty || targets.contains(id);
}

class _Drag extends StatelessWidget {
  const _Drag({required this.spec});

  final _DragSpec spec;

  @override
  Widget build(BuildContext context) {
    final child = spec.child ?? const SizedBox.shrink();
    if (spec.disabled || spec.payload.isEmpty) return child;
    // O que voa com o cursor mora no Overlay, fora do painel: leva junto o
    // estilo do texto, e um tamanho, que lá ninguém dá.
    final style = DefaultTextStyle.of(context).style;
    final width = spec.width ?? context.size?.width ?? 280;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<_Payload>(
        data: _Payload(spec.payload, spec.targets),
        onDragStarted: () => _dragging.value = spec.targets,
        onDragEnd: (_) => _dragging.value = null,
        onDraggableCanceled: (_, _) => _dragging.value = null,
        feedback: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: style,
            child: Transform.rotate(
              angle: 0.035,
              child: Container(
                width: width,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(color: Color(0x55000000), blurRadius: 24, offset: Offset(0, 10)),
                  ],
                ),
                child: spec.feedback ?? child,
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: child),
        child: child,
      ),
    );
  }
}

typedef _DropSpec = ({
  String id,
  String? hint,
  Color? color,
  Color? hoverColor,
  double radius,
  Widget? child,
  void Function(DynamicMap)? onDrop,
});

_DropSpec _readDrop(DataSource s) => (
  id: s.v<String>(['id']) ?? '',
  hint: s.v<String>(['hint']),
  color: ArgumentDecoders.color(s, ['color']),
  hoverColor: ArgumentDecoders.color(s, ['hoverColor']),
  radius: s.v<double>(['radius']) ?? 0,
  child: s.optionalChild(['child']),
  onDrop: s.handler<void Function(DynamicMap)>(
    ['onDrop'],
    (trigger) =>
        (extra) => trigger(extra),
  ),
);

class _Drop extends StatelessWidget {
  const _Drop({required this.spec});

  final _DropSpec spec;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(spec.radius);
    return DragTarget<_Payload>(
      onWillAcceptWithDetails: (d) => d.data.fits(spec.id),
      onAcceptWithDetails: (d) =>
          spec.onDrop?.call(<String, Object?>{'payload': d.data.value, 'to': spec.id}),
      builder: (context, candidates, _) {
        final over = candidates.isNotEmpty;
        return ValueListenableBuilder<List<String>?>(
          valueListenable: _dragging,
          builder: (context, targets, _) {
            final fits = targets != null && (targets.isEmpty || targets.contains(spec.id));
            final accent = Mx.accent;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              foregroundDecoration: BoxDecoration(
                borderRadius: radius,
                border: over
                    ? Border.all(color: accent, width: 2)
                    : fits
                    ? Border.all(color: accent.withValues(alpha: 0.35), width: 1.5)
                    : null,
              ),
              decoration: BoxDecoration(
                borderRadius: radius,
                color: over ? (spec.hoverColor ?? accent.withValues(alpha: 0.10)) : spec.color,
              ),
              // O filho é quem dá o tamanho: o alvo mora em qualquer lugar,
              // até numa lista horizontal, onde a largura não tem fim. Um
              // Stack só de posicionados não teria tamanho nenhum ali.
              child: Stack(
                children: [
                  spec.child ?? const SizedBox.shrink(),
                  if (over && spec.hint != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 14,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: accent,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              spec.hint!,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color:
                                    ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
                                    ? Colors.white
                                    : Mx.canvas,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
