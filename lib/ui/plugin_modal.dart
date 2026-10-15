import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/store.dart';
import '../theme.dart';
import 'panel.dart';
import 'plugin_pane.dart';

/// As âncoras das janelas de plugin, por `pluginId/id`: de onde um modal sai
/// e pra onde ele volta. Ver [PluginAnchor].
final Map<String, GlobalKey> _anchors = {};

/// O retângulo da âncora [id] do plugin [pluginId] na tela (já com a escala de
/// quem estiver em volta -- o `FittedBox` do escritório), ou `null` se ela não
/// está na tela.
Rect? pluginAnchorRect(String pluginId, String id) {
  final box = _anchors['$pluginId/$id']?.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

/// O `Anchor` de `import maestria;`: marca um pedaço da janela como o lugar de
/// onde um modal sai (`view.open` com `from`). No escritório, o boneco: o chat
/// dele cresce a partir dele e, fechando, volta pra ele.
class PluginAnchor extends StatefulWidget {
  const PluginAnchor({
    super.key,
    required this.pluginId,
    required this.id,
    required this.child,
  });

  final String pluginId;
  final String id;
  final Widget child;

  @override
  State<PluginAnchor> createState() => _PluginAnchorState();
}

class _PluginAnchorState extends State<PluginAnchor> {
  final GlobalKey _key = GlobalKey();

  String get _name => '${widget.pluginId}/${widget.id}';

  @override
  void initState() {
    super.initState();
    _anchors[_name] = _key;
  }

  @override
  void didUpdateWidget(PluginAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = '${oldWidget.pluginId}/${oldWidget.id}';
    if (old != _name && _anchors[old] == _key) _anchors.remove(old);
    _anchors[_name] = _key;
  }

  @override
  void dispose() {
    if (_anchors[_name] == _key) _anchors.remove(_name);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _key, child: widget.child);
}

/// A janela de plugin em modal (`view.open` com `modal: true`): por cima da
/// tela, com o fundo escurecido, até você fechar (o x, o esc ou o clique fora)
/// ou mandá-la pra grade ("abrir como painel"). O conteúdo é o de uma janela
/// qualquer -- o [PluginPane] sem a moldura de painel. Ver [AppStore.pluginModal].
///
/// Abre crescendo e fecha encolhendo: a partir da âncora que o plugin disse
/// (`from`, ver [PluginAnchor]) -- o zoom saindo do boneco e voltando pra ele
/// --, ou no meio da tela, sem âncora. Fechar mantém o modal na tela o tempo
/// da animação; mandá-lo pra grade não anima (ele vira painel na hora).
class PluginModalLayer extends StatefulWidget {
  const PluginModalLayer({super.key, required this.store});

  final AppStore store;

  @override
  State<PluginModalLayer> createState() => _PluginModalLayerState();
}

class _PluginModalLayerState extends State<PluginModalLayer> {
  /// O que está desenhado: o modal da vez, ou o que está fechando.
  MxTab? _shown;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.store.pluginModal;
    widget.store.addListener(_changed);
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final now = widget.store.pluginModal;
    if (now == _shown && !(_closing && now != null)) return;
    setState(() {
      if (now != null) {
        _shown = now;
        _closing = false;
      } else if (_shown != null && !widget.store.tabs.contains(_shown)) {
        // Fechou (e não foi pra grade): fica até a animação de sair acabar.
        _closing = true;
      } else {
        _shown = null;
        _closing = false;
      }
    });
  }

  void _gone() {
    if (!mounted || !_closing) return;
    setState(() {
      _shown = null;
      _closing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tab = _shown;
    if (tab == null) return const SizedBox.shrink();
    return _Modal(
      key: ValueKey(tab.id),
      store: widget.store,
      tab: tab,
      closing: _closing,
      onGone: _gone,
    );
  }
}

class _Modal extends StatefulWidget {
  const _Modal({
    super.key,
    required this.store,
    required this.tab,
    required this.closing,
    required this.onGone,
  });

  final AppStore store;
  final MxTab tab;
  final bool closing;
  final VoidCallback onGone;

  @override
  State<_Modal> createState() => _ModalState();
}

class _ModalState extends State<_Modal> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 260),
  )..forward();

  /// De onde o modal sai (e pra onde volta), na tela; `null` é o meio.
  Rect? _from;

  @override
  void initState() {
    super.initState();
    _from = _anchor();
  }

  @override
  void didUpdateWidget(_Modal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.closing && !oldWidget.closing) {
      // O boneco pode ter andado desde que o chat abriu: volta pra onde ele está.
      _from = _anchor() ?? _from;
      _t.reverse().whenComplete(widget.onGone);
    } else if (!widget.closing && oldWidget.closing) {
      _t.forward();
    }
  }

  Rect? _anchor() {
    final view = widget.tab.view;
    final from = view?.modalFrom;
    if (view == null || from == null) return null;
    return pluginAnchorRect(view.pluginId, from);
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  void _close() {
    if (!widget.closing) widget.store.closeModal();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final store = widget.store;
    final view = tab.view!;
    final plugin = store.plugins.byId(view.pluginId);
    final curve = CurvedAnimation(
      parent: _t,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final width = (view.modalWidth ?? box.maxWidth - 48).clamp(
              320.0,
              (box.maxWidth - 48).clamp(320.0, 820.0),
            );
            final height = (view.modalHeight ?? box.maxHeight - 48).clamp(
              240.0,
              box.maxHeight * 0.88,
            );
            final end = Rect.fromCenter(
              center: box.biggest.center(Offset.zero),
              width: width,
              height: height,
            );
            // A âncora em coordenadas desta camada (que não começa, necessariamente, no canto da janela).
            final layer = context.findRenderObject();
            final origin = layer is RenderBox && layer.hasSize
                ? layer.localToGlobal(Offset.zero)
                : Offset.zero;
            final from = _from?.shift(-origin);
            return AnimatedBuilder(
              animation: curve,
              builder: (context, child) {
                final t = curve.value;
                // Sem âncora: o de sempre, um quase nada de escala no meio.
                final start =
                    from ??
                    Rect.fromCenter(
                      center: end.center,
                      width: end.width * 0.97,
                      height: end.height * 0.97,
                    );
                final scale =
                    (start.width / end.width +
                            (1 - start.width / end.width) * t)
                        .clamp(0.02, 1.0);
                final center = Offset.lerp(start.center, end.center, t)!;
                final offset =
                    center -
                    end.topLeft -
                    Offset(end.width, end.height) * (scale / 2);
                return Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: _close,
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.42 * t),
                        ),
                      ),
                    ),
                    Positioned.fromRect(
                      rect: end,
                      child: Transform(
                        transform: Matrix4.identity()
                          ..translateByDouble(offset.dx, offset.dy, 0, 1)
                          ..scaleByDouble(scale, scale, 1, 1),
                        child: Opacity(
                          opacity: (t * 1.6).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: Container(
                decoration: BoxDecoration(
                  color: Mx.bg,
                  borderRadius: BorderRadius.circular(Mx.radius + 4),
                  border: Border.all(color: Mx.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      Container(
                        height: 44,
                        padding: const EdgeInsets.only(left: 14, right: 8),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: Mx.border)),
                        ),
                        child: Row(
                          children: [
                            PluginGlyph(
                              icon: plugin?.manifest?.icon,
                              dir: plugin?.dir,
                              size: 17,
                            ),
                            const SizedBox(width: 9),
                            // Título e subtítulo numa linha só deles: lado
                            // a lado com os botões, o título curto deixava
                            // a parte dele do espaço livre depois do x, e
                            // os botões boiavam longe da borda.
                            Expanded(
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      tab.title,
                                      overflow: TextOverflow.ellipsis,
                                      style: paneTitleStyle.copyWith(
                                        color: Mx.fg,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    flex: 2,
                                    child: Text(
                                      tab.subtitle,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Mx.fgDim,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Os mesmos botões de ícone do cabeçalho do
                            // painel: o modal é a mesma janela, só por cima.
                            IconButton(
                              tooltip: 'abrir como painel',
                              iconSize: 15,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 26,
                                height: 26,
                              ),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: store.dockModal,
                              icon: Icon(
                                Icons.vertical_split_outlined,
                                color: Mx.fgDim,
                              ),
                            ),
                            IconButton(
                              tooltip: 'fechar (esc)',
                              iconSize: 15,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 26,
                                height: 26,
                              ),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: _close,
                              icon: Icon(Icons.close, color: Mx.fgDim),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: PluginPane(
                          store: store,
                          tab: tab,
                          framed: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
