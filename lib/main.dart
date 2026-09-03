// `AppExitResponse` mora aqui e em nenhum outro lugar: o `material.dart` não
// reexporta. `show` porque o `dart:ui` inteiro traria um `TextStyle`, uma
// `Image` e uma `Color` pra brigar com os do material.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'services/store.dart';
import 'theme.dart';
import 'ui/keys.dart';
import 'ui/panel.dart';
import 'ui/panes.dart';
import 'ui/sidebar.dart';

void main() {
  runApp(const MaestriaApp());
}

class MaestriaApp extends StatefulWidget {
  const MaestriaApp({super.key});

  @override
  State<MaestriaApp> createState() => _MaestriaAppState();
}

class _MaestriaAppState extends State<MaestriaApp> {
  final AppStore store = AppStore();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // O gancho do ⌘Q, e o único momento em que ainda dá pra encerrar as
    // sessões.
    //
    // `dispose` não serve pra isso: quando o macOS encerra o app a árvore de
    // widgets não é desmontada, ela some junto com o processo -- e as sessões
    // não vão junto, porque cada uma é uma sessão de terminal própria (ver
    // `TermSession.kill`) e nada manda o hangup por nós. Sem isto, todo
    // painel que estava aberto ao sair vira um `claude` órfão rodando pra
    // sempre, um por vez que o app foi usado.
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    store.init();
  }

  Future<AppExitResponse> _onExitRequested() async {
    await store.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Above the MaterialApp on purpose: the palette feeds `theme:` as much as
    // it feeds the panels, so the whole tree has to be rebuilt from up here.
    // A tipografia vem junto (ver [Mx.chrome]) pelo mesmo motivo: a face mono
    // é lida tanto pelo pty quanto pelos rótulos ao redor dele.
    return AnimatedBuilder(
      animation: Mx.chrome,
      builder: (context, _) => MaterialApp(
        title: 'maestria',
        debugShowCheckedModeBanner: false,
        theme: Mx.theme(),
        home: AnimatedBuilder(
          animation: store,
          builder: (context, _) => Scaffold(
            body: Builder(
              // A context under the Navigator, so a shortcut can open a dialog.
              builder: (ctx) => _Keys(
                store: store,
                context: ctx,
                // The gutter around and between the panels. Everything the
                // window shows is a card on the canvas; this is the canvas.
                child: Padding(
                  padding: const EdgeInsets.all(Mx.gap),
                  child: Column(
                    // The banner spans the whole window; only the row of
                    // panels above it is split.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          // The stored width is a wish, not a promise: a window
                          // narrow enough would otherwise leave the panes with
                          // negative space to lay out in.
                          builder: (context, box) => Row(
                            children: [
                              SizedBox(
                                width: store.sidebarWidth.clamp(
                                  AppStore.minSidebar,
                                  (box.maxWidth - 280).clamp(AppStore.minSidebar, double.infinity),
                                ),
                                child: Sidebar(store: store),
                              ),
                              _SidebarGrip(store: store),
                              Expanded(child: PaneArea(store: store)),
                            ],
                          ),
                        ),
                      ),
                      if (store.banner != null) ...[
                        const SizedBox(height: Mx.gap),
                        _Banner(store: store),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The gutter between the sidebar and the panes, made draggable.
///
/// It is exactly [Mx.gap] wide, so grabbing it costs the layout nothing — the
/// gap was always there. Double-click puts the sidebar back where it started.
class _SidebarGrip extends StatefulWidget {
  const _SidebarGrip({required this.store});
  final AppStore store;

  @override
  State<_SidebarGrip> createState() => _SidebarGripState();
}

class _SidebarGripState extends State<_SidebarGrip> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        onHorizontalDragUpdate: (d) =>
            widget.store.setSidebarWidth(widget.store.sidebarWidth + d.delta.dx),
        onDoubleTap: () => widget.store.setSidebarWidth(AppStore.defaultSidebar),
        child: SizedBox(
          width: Mx.gap,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 3,
              height: lit ? 46 : 0,
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

/// The keyboard map.
///
/// It sits above the terminals on purpose: xterm does not claim combinations
/// with ⌘, so they bubble up here instead of being typed into the shell. What
/// each key does is in [MxKeys]; which key does it is in the settings page,
/// and this only asks the store for the answer of the moment.
class _Keys extends StatelessWidget {
  const _Keys({required this.store, required this.context, required this.child});

  final AppStore store;
  // ignore: use_build_context_synchronously
  final BuildContext context;
  final Widget child;

  @override
  Widget build(BuildContext _) {
    return CallbackShortcuts(
      bindings: MxKeys.bindings(store, context),
      // A focus node of our own, always in the subtree.
      //
      // Key events travel up from whatever holds primary focus; with no panel
      // open nothing below did, so the whole map was dead until the first
      // terminal existed. This node holds focus in that gap and steps aside
      // the moment a TerminalView wants it.
      child: Focus(autofocus: true, child: child),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return MxPanel(
      color: Mx.bgActive,
      radius: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 14, color: Mx.fgDim),
            const SizedBox(width: 8),
            Expanded(
              child: Text(store.banner!, style: TextStyle(fontSize: 11.5, color: Mx.fgDim)),
            ),
            InkWell(
              onTap: store.clearBanner,
              child: Icon(Icons.close, size: 13, color: Mx.fgFaint),
            ),
          ],
        ),
      ),
    );
  }
}
