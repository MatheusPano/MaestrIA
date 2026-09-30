// `AppExitResponse` mora aqui e em nenhum outro lugar: o `material.dart` não
// reexporta. `show` porque o `dart:ui` inteiro traria um `TextStyle`, uma
// `Image` e uma `Color` pra brigar com os do material.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'services/store.dart';
import 'theme.dart';
import 'ui/icons.dart';
import 'ui/keys.dart';
import 'ui/notices.dart';
import 'ui/panes.dart';
import 'ui/plugin_dialogs.dart';
import 'ui/plugin_float.dart';
import 'ui/sidebar.dart';
import 'ui/sidebar_rail.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Compila os svgs antes do primeiro quadro. Sem isto a marca do claude, que
  // é o desenho mais repetido da lista, chega um quadro depois da linha em que
  // mora -- e a lista inteira pisca ao abrir. Ver [MxIcon.warm].
  MxIcon.warm();
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
    // O foco da janela, que é a outra metade de "parou sem você ver": um
    // painel que termina com a janela atrás do navegador é notícia, e o mesmo
    // painel terminando na sua frente não é. Ver [AppStore.setWindowActive].
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onResume: () => store.setWindowActive(true),
      onInactive: () => store.setWindowActive(false),
    );
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
              builder: (ctx) {
                // O seletor rápido dos plugins precisa de um contexto debaixo
                // do navegador, e é aqui que há um. Ver [AppStore.quickPick].
                store.quickPick = ({required title, placeholder, required items}) =>
                    showQuickPick(ctx, title: title, placeholder: placeholder, items: items);
                final top = store.statusBarTop;
                final banner = _Banner(
                  // A chave é o texto: recado novo é widget novo, e a entrada
                  // roda de novo em vez de trocar as letras em silêncio.
                  key: ValueKey(store.banner),
                  store: store,
                );
                return _Keys(
                  store: store,
                  context: ctx,
                  // The gutter around and between the panels. Everything the
                  // window shows is a card on the canvas; this is the canvas.
                  //
                  // Embaixo de tudo -- ou em cima, ver [AppStore.statusBarTop]
                  // --, a barra de status: a janela inteira de largura, no
                  // canvas e não num cartão -- é a moldura, não um painel. Ver
                  // [StatusBar].
                  child: Column(
                    children: [
                      if (top) StatusBar(store: store),
                      Expanded(
                        child: Stack(
                          children: [
                            Padding(
                              // Sem o vão do lado da barra: a barra de status é o que
                              // separa os cartões da borda da janela.
                              padding: EdgeInsets.fromLTRB(
                                Mx.gap,
                                top ? 0 : Mx.gap,
                                Mx.gap,
                                top ? Mx.gap : 0,
                              ),
                              child: LayoutBuilder(
                                // The stored width is a wish, not a promise: a window
                                // narrow enough would otherwise leave the panes with
                                // negative space to lay out in.
                                builder: (context, box) => Row(
                                  children: [
                                    // Escondida, a lateral sai da fileira inteira -- não
                                    // fica com largura zero. Um `Sidebar` de 0px continua
                                    // montado, e uma lista de trinta linhas que ninguém vê
                                    // é trinta linhas sendo medidas a cada quadro. Ver
                                    // [AppStore.sidebarHidden].
                                    //
                                    // A faixa vem antes, no canvas, e fica mesmo com a
                                    // lateral escondida -- aí é ela a volta. Ver
                                    // [SidebarRail].
                                    SidebarRail(store: store),
                                    if (!store.sidebarHidden) ...[
                                      SizedBox(
                                        width: store.sidebarWidth.clamp(
                                          AppStore.minSidebar,
                                          (box.maxWidth - 280).clamp(
                                            AppStore.minSidebar,
                                            double.infinity,
                                          ),
                                        ),
                                        child: Sidebar(store: store),
                                      ),
                                      _SidebarGrip(store: store),
                                    ],
                                    Expanded(
                                      // O recado flutua por cima dos painéis em vez de ser
                                      // uma faixa embaixo deles. Como filho da Column ele
                                      // roubava altura da fileira inteira ao aparecer, e
                                      // `terminal.onResize` manda isso pro pty: um
                                      // "caminho copiado" reformatava treze sessões, e
                                      // reformatava de novo ao sumir.
                                      child: Stack(
                                        children: [
                                          PaneArea(store: store),
                                          // A lista do sino, no canto de baixo à direita:
                                          // logo acima do sino, que mora na ponta direita
                                          // da barra de status.
                                          if (store.noticesOpen)
                                            Positioned(
                                              right: Mx.gap,
                                              top: top ? Mx.gap : null,
                                              bottom: top ? null : Mx.gap,
                                              child: NoticeCenter(store: store),
                                            ),
                                          // Os cartões do sino e o recado moram no mesmo
                                          // canto, empilhados -- e com a lista aberta
                                          // esperariam atrás dela.
                                          //
                                          // Montado mesmo sem cartão nenhum: o último
                                          // a sair ainda tem o deslize dele pra fazer.
                                          // Vazio, é uma coluna de altura zero.
                                          if (!store.noticesOpen)
                                            Positioned(
                                              // Os dois lados presos: um Positioned só com
                                              // `right` deixa a largura sem teto, e um
                                              // Text sem teto não sabe onde quebrar.
                                              left: Mx.gap,
                                              right: Mx.gap,
                                              top: top ? Mx.gap : null,
                                              bottom: top ? null : Mx.gap,
                                              child: Align(
                                                alignment: top
                                                    ? Alignment.topRight
                                                    : Alignment.bottomRight,
                                                // O recado fica colado na barra, e os
                                                // cartões do lado de dentro dele.
                                                child: Column(
                                                  mainAxisSize: MainAxisSize.min,
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    if (top && store.banner != null) banner,
                                                    NoticeToasts(store: store),
                                                    if (!top && store.banner != null) banner,
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // A lista das sessões, aberta pelo resumo da barra:
                            // na coluna dele, que é a borda do cartão da lateral.
                            if (store.sessionsOpen)
                              Positioned(
                                left: StatusBar.inset,
                                top: top ? Mx.gap : null,
                                bottom: top ? null : Mx.gap,
                                child: SessionList(store: store),
                              ),
                            // Os painéis pequenos dos plugins (`float.show`), por
                            // cima de tudo o que fica acima da barra: a lateral e os
                            // painéis. Ver [PluginFloatLayer].
                            Positioned.fill(child: PluginFloatLayer(store: store)),
                          ],
                        ),
                      ),
                      if (!top) StatusBar(store: store),
                    ],
                  ),
                );
              },
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
      //
      // É também quem atende as teclas dos plugins fora do terminal: o evento
      // sobe do foco até aqui antes de chegar no mapa acima, então o que o
      // app responde é deixado passar -- ver [Plugins.commandFor].
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          final command = store.plugins.commandFor(event, except: store.keymap);
          if (command == null) return KeyEventResult.ignored;
          store.runPluginCommand(command);
          return KeyEventResult.handled;
        },
        child: child,
      ),
    );
  }
}

/// O x do recado: quadradinho que acende no hover, como o do VS Code.
class _BannerClose extends StatefulWidget {
  const _BannerClose({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_BannerClose> createState() => _BannerCloseState();
}

class _BannerCloseState extends State<_BannerClose> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _hover ? Mx.bgHover : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(Icons.close, size: 14, color: _hover ? Mx.fg : Mx.fgDim),
        ),
      ),
    );
  }
}

/// O recado da janela: um cartão no canto de baixo, por [AppStore.bannerLife].
///
/// Encolhe pro tamanho do texto — `mainAxisSize.min` — porque um "caminho
/// copiado" numa faixa de ponta a ponta era uma barra de status anunciando um
/// clique. O teto de 460 é onde as frases longas quebram em duas linhas em vez
/// de atravessar a área de painéis.
class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          // Sobe os últimos pixels ao entrar: o recado vem de fora da janela,
          // não aparece do nada em cima do painel.
          child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
        ),
        // O cartão das notificações do VS Code: fundo da janela, contorno na
        // cor de destaque do tema e uma sombra que o descola dos painéis. O
        // cinza sobre cinza de antes sumia em cima de um terminal escuro.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Mx.accent.withValues(alpha: 0.7)),
            boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6))],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  // Alinha o ícone com a primeira linha, não com o meio do bloco.
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.info_outline, size: 16, color: Mx.accent),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    store.banner!,
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: Mx.fg),
                  ),
                ),
                const SizedBox(width: 12),
                _BannerClose(onTap: store.clearBanner),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
