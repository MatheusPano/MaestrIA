import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'sidebar_rail.dart';

/// O grupo de toque do sino: o botão e a lista contam como um lugar só, então
/// clicar no botão com a lista aberta fecha pelo botão -- e não fecha pelo
/// "clicou fora" pra reabrir logo em seguida pelo botão.
const noticeTapGroup = #mxNotices;

/// O mesmo, pro resumo das sessões e a lista que ele abre.
const sessionsTapGroup = #mxSessions;

/// A faixa na borda da janela, no molde da barra de status do VS Code: o
/// resumo das sessões à esquerda e o sino na ponta direita. No pé, ou no topo
/// se [AppStore.statusBarTop] -- o sino e os cartões vão junto.
///
/// No canvas e sem borda: é a moldura da janela, não mais um cartão. A altura
/// que ela ocupa é fixa -- nada nela aparece ou some a ponto de mudar o
/// tamanho dos painéis, e é isso que a deixa morar fora do [Stack] dos
/// recados: o tamanho do pty não depende do que ela diz.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.store});
  final AppStore store;

  static const height = 26.0;

  /// Onde o resumo começa: na borda do cartão da lateral, e não na da janela.
  /// A faixa de ícones fica à esquerda dela a janela inteira de altura, e o
  /// texto embaixo da faixa lia como mais um ícone dela.
  static const inset = Mx.gap + SidebarRail.width + Mx.gap;

  @override
  Widget build(BuildContext context) {
    // Centrar na conta não centra no olho: de um lado da barra está a borda
    // dos cartões, do outro a borda da janela, e o vão do lado dos cartões
    // lia maior. Os 3px a mais do lado da janela levam o conteúdo pro meio
    // que se vê.
    final top = store.statusBarTop;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, top ? 3 : 0, Mx.gap + 4, top ? 0 : 3),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _SessionSummary(store: store),
              ),
            ),
            NoticeBell(store: store),
          ],
        ),
      ),
    );
  }
}

/// As sessões do claude que a barra conta: as que ainda têm processo.
List<MxTab> _liveSessions(AppStore store) =>
    store.tabs.where((t) => t.kind == TabKind.claude && !t.exited).toList();

bool _working(MxTab t) => t.status == ClaudeStatus.working || t.status == ClaudeStatus.tool;

bool _waiting(MxTab t) => !t.done && t.status.needsHuman;

/// "6 sessões · 1 trabalhando", e o clique que abre a lista delas. A conta
/// dizia quantas estavam esperando sem dizer quais -- ver [SessionList].
class _SessionSummary extends StatefulWidget {
  const _SessionSummary({required this.store});
  final AppStore store;

  @override
  State<_SessionSummary> createState() => _SessionSummaryState();
}

class _SessionSummaryState extends State<_SessionSummary> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final claude = _liveSessions(store);
    final working = claude.where(_working).length;
    final waiting = claude.where(_waiting).length;
    final open = store.sessionsOpen;
    return TapRegion(
      groupId: sessionsTapGroup,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: store.toggleSessions,
          child: Container(
            height: 20,
            // O mesmo alvo do sino, do outro lado: o vão de 6 é o que põe o
            // texto na coluna do primeiro ícone do rodapé da lateral.
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: _hover || open ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            // O alvo é o texto, não a barra: um `alignment` no Container o
            // estica até o sino. O `widthFactor` centra na altura e fica na
            // largura do que está escrito.
            child: Center(
              widthFactor: 1,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${claude.length} ${claude.length == 1 ? 'sessão' : 'sessões'}'),
                    if (working > 0) TextSpan(text: '  ·  $working trabalhando'),
                    if (waiting > 0)
                      TextSpan(
                        text: '  ·  $waiting esperando você',
                        style: TextStyle(color: Mx.yellow),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Altura 1 com o respiro dividido igual: o `bodyMedium` do M3
                // traz 1.43 de altura de linha, e o vão sobra desigual em cima
                // e embaixo do texto -- que é o que o deixava fora do eixo do
                // sino ao lado.
                textHeightBehavior: const TextHeightBehavior(
                  leadingDistribution: TextLeadingDistribution.even,
                ),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1,
                  color: _hover || open ? Mx.fgDim : Mx.fgFaint,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A lista que o resumo da barra abre: as sessões do claude, em três blocos
/// -- as que esperam você, as que estão trabalhando, e o resto aberto. O
/// clique numa linha põe a sessão na tela.
///
/// Mais curta que a lateral de propósito: a lateral é por pasta, e a pergunta
/// aqui é outra -- "quem quer o quê de mim agora", em todas as pastas, mesmo
/// com a lateral escondida ou numa aba de plugin.
class SessionList extends StatelessWidget {
  const SessionList({super.key, required this.store});
  final AppStore store;

  static const width = 360.0;

  @override
  Widget build(BuildContext context) {
    final claude = _liveSessions(store);
    final waiting = claude.where(_waiting).toList();
    final working = claude.where((t) => !_waiting(t) && _working(t)).toList();
    final rest = claude.where((t) => !_waiting(t) && !_working(t)).toList();
    final top = store.statusBarTop;
    return TapRegion(
      groupId: sessionsTapGroup,
      onTapOutside: (_) => store.closeSessions(),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (top ? -8 : 8) * (1 - t)), child: child),
        ),
        child: Container(
          width: width,
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Mx.border),
            boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6))],
          ),
          clipBehavior: Clip.antiAlias,
          child: claude.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Nenhuma sessão do Claude aberta',
                    style: TextStyle(fontSize: 12, color: Mx.fgFaint),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 6),
                  children: [
                    if (waiting.isNotEmpty) ..._block('Esperando você', waiting),
                    if (working.isNotEmpty) ..._block('Trabalhando', working),
                    if (rest.isNotEmpty) ..._block('Abertas', rest),
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _block(String label, List<MxTab> tabs) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        '$label  ${tabs.length}',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: Mx.fgFaint,
        ),
      ),
    ),
    for (final t in tabs) _SessionRow(key: ObjectKey(t), store: store, tab: t),
  ];
}

class _SessionRow extends StatefulWidget {
  const _SessionRow({super.key, required this.store, required this.tab});
  final AppStore store;
  final MxTab tab;

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tab;
    final store = widget.store;
    // A que está com o teclado: é a que você já está olhando.
    final here = store.focusedPaneId == t.id;
    final where = [if (!t.folder.isLoose) t.folder.name, t.subtitle].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => store.openSession(t),
        child: Container(
          color: _hover ? Mx.bgHover : (here ? Mx.bgActive : Colors.transparent),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              ClaudeAvatar(status: t.status, size: 18, dim: t.done),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                        color: Mx.fg,
                      ),
                    ),
                    Text(
                      where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, height: 1.3, color: Mx.fgFaint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(t.status.label, style: TextStyle(fontSize: 11, color: t.status.color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// O sino da barra de status, com o número do que você ainda não viu ao lado.
class NoticeBell extends StatefulWidget {
  const NoticeBell({super.key, required this.store});
  final AppStore store;

  @override
  State<NoticeBell> createState() => _NoticeBellState();
}

class _NoticeBellState extends State<NoticeBell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final unread = store.unreadNotices;
    final quiet = store.doNotDisturb;
    final lit = store.noticesOpen || unread > 0;
    final color = lit ? Mx.accent : (_hover ? Mx.fg : Mx.fgDim);
    return TapRegion(
      groupId: noticeTapGroup,
      child: Tooltip(
        message: [
          'Notificações',
          if (unread > 0) '$unread nova${unread == 1 ? '' : 's'}',
          if (quiet) 'não perturbe',
        ].join(' · '),
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: store.toggleNotices,
            child: Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: _hover || store.noticesOpen ? Mx.bgHover : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    quiet
                        ? Icons.notifications_off_outlined
                        : unread == 0
                        ? Icons.notifications_none_outlined
                        : Icons.notifications_outlined,
                    size: 15,
                    color: color,
                  ),
                  if (unread > 0) ...[
                    const SizedBox(width: 4),
                    Text(
                      unread > 99 ? '99+' : '$unread',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Quanto dura a entrada ou a saída de um aviso: o cartão deslizando pra
/// dentro da tela, a linha da lista deslizando pra fora. Curto o bastante pra
/// não fazer ninguém esperar, longo o bastante pra se ver de onde veio.
const _slide = Duration(milliseconds: 280);

/// O intervalo entre uma linha e a seguinte no "limpar tudo": a lista sai em
/// cascata, de cima pra baixo, em vez de sumir de uma vez.
const _cascade = Duration(milliseconds: 35);

/// Quantas linhas esperam a vez na cascata. A lista não mostra mais que isso,
/// e as de baixo saem junto com a última -- ninguém as vê.
const _cascadeCap = 8;

/// O fecho do "limpar tudo": com as linhas já fora, o cartão encolhe de uma
/// vez até o recado de vazio.
const _settle = Duration(milliseconds: 220);

/// Zero quando o sistema pede menos movimento: o aviso aparece e some igual,
/// só que sem viagem.
Duration _motion(BuildContext context, Duration d) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;

/// O contorno dos cartões do sino, pintado por cima do conteúdo e não por
/// baixo: na `decoration` ele fica atrás dos filhos, e o fundo do hover de
/// uma linha encostada na borda cobria o traço -- o cartão perdia o contorno
/// justo onde o ponteiro estava.
BoxDecoration _outline() => BoxDecoration(
  borderRadius: BorderRadius.circular(8),
  border: Border.all(color: Mx.accent.withValues(alpha: 0.7)),
);

/// A lista do sino, no molde da central de notificações do VS Code: um
/// cartão com contorno na cor de destaque, cabeçalho com as ações de tudo, e
/// uma linha por aviso -- que leva até o painel quando clicada.
class NoticeCenter extends StatefulWidget {
  const NoticeCenter({super.key, required this.store});
  final AppStore store;

  static const width = 380.0;

  @override
  State<NoticeCenter> createState() => _NoticeCenterState();
}

class _NoticeCenterState extends State<NoticeCenter> with SingleTickerProviderStateMixin {
  /// As linhas saindo pelo x. A linha só sai do sino quando a animação dela
  /// termina -- ver [_Leaving].
  final Map<MxNotice, Duration> _leaving = {};

  /// O "limpar tudo", num relógio só: a cascata das linhas e depois o fecho.
  ///
  /// As linhas saem sem fechar o vão que deixam. O cartão é preso pela borda
  /// de baixo, e cada linha encolhendo na sua vez fazia o cabeçalho descer
  /// aos trancos enquanto as outras ainda deslizavam. Vazias todas, a altura
  /// cai num movimento só.
  late final _sweep = AnimationController(vsync: this)..addStatusListener(_swept);

  /// As linhas do "limpar tudo" e a vez de cada uma na cascata.
  final Map<MxNotice, int> _order = {};

  /// A vez da última linha, que é onde a cascata acaba e o fecho começa.
  int _last = 0;

  Duration get _span => _cascade * _last + _slide + _settle;

  /// Um instante da varrida, como fração do relógio dela.
  double _at(Duration d) => d.inMicroseconds / _span.inMicroseconds;

  @override
  void dispose() {
    // Fechado no meio da varrida, por um clique fora: o gesto já foi feito,
    // só não chega a ser visto. Fora do dispose, que é no meio de um frame.
    if (_order.isNotEmpty) {
      final store = widget.store;
      final all = List.of(_order.keys);
      scheduleMicrotask(() => _dismissAll(store, all));
    }
    _sweep.dispose();
    super.dispose();
  }

  void _dismiss(MxNotice n) => setState(() => _leaving[n] = Duration.zero);

  void _clearAll() {
    // As que já saem pelo x terminam a saída delas.
    final all = widget.store.notices.where((n) => !_leaving.containsKey(n)).toList();
    if (all.isEmpty) return;
    setState(() {
      for (final (i, n) in all.indexed) {
        _order[n] = i.clamp(0, _cascadeCap);
      }
      _last = (all.length - 1).clamp(0, _cascadeCap);
    });
    _sweep.duration = _motion(context, _span);
    _sweep.forward(from: 0);
  }

  void _swept(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final all = List.of(_order.keys);
    setState(_order.clear);
    _dismissAll(widget.store, all);
  }

  static void _dismissAll(AppStore store, List<MxNotice> all) {
    for (final n in all) {
      if (store.notices.contains(n)) store.dismissNotice(n);
    }
  }

  void _gone(MxNotice n) {
    _leaving.remove(n);
    if (widget.store.notices.contains(n)) widget.store.dismissNotice(n);
  }

  /// A linha na vez dela da cascata: desliza pra direita e apaga, e o lugar
  /// dela fica -- quem fecha o vão é o fecho, de uma vez.
  Widget _out(int at, Widget child) {
    final start = _cascade * at;
    final move = _sweep.drive(
      CurveTween(curve: Interval(_at(start), _at(start + _slide), curve: Curves.easeInCubic)),
    );
    return IgnorePointer(
      child: FadeTransition(
        opacity: ReverseAnimation(move),
        child: SlideTransition(
          position: move.drive(Tween(begin: Offset.zero, end: const Offset(1, 0))),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final notices = store.notices;
    // Só encolhe até o vazio se não sobra nada: um aviso que chegou no meio
    // da varrida fica, e a lista com ele.
    final settles = _order.isNotEmpty && notices.every(_order.containsKey);
    final settle = _sweep.drive(
      CurveTween(
        curve: Interval(_at(_cascade * _last + _slide), 1, curve: Curves.easeInOutCubic),
      ),
    );
    return TapRegion(
      groupId: noticeTapGroup,
      onTapOutside: (_) => store.closeNotices(),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          // Sobe de perto do sino: de baixo com a barra no pé, de cima com
          // ela no topo.
          child: Transform.translate(
            offset: Offset(0, (store.statusBarTop ? -8 : 8) * (1 - t)),
            child: child,
          ),
        ),
        child: Container(
          width: NoticeCenter.width,
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6))],
          ),
          foregroundDecoration: _outline(),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(store: store, onClear: _order.isEmpty ? _clearAll : null),
              if (notices.isEmpty)
                const _Empty()
              else ...[
                Flexible(
                  child: SizeTransition(
                    sizeFactor: settles ? ReverseAnimation(settle) : kAlwaysCompleteAnimation,
                    alignment: AlignmentDirectional.topStart,
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 4),
                      itemCount: notices.length,
                      itemBuilder: (_, i) {
                        final n = notices[i];
                        final at = _order[n];
                        // O divisor vai dentro da linha, e não entre elas: uma
                        // linha que encolhe até sumir leva o traço dela junto.
                        final row = Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (i > 0) Divider(height: 1, thickness: 1, color: Mx.border),
                            _NoticeRow(store: store, notice: n, onDismiss: () => _dismiss(n)),
                          ],
                        );
                        return _Leaving(
                          key: ObjectKey(n),
                          leaving: _leaving[n],
                          onGone: () => _gone(n),
                          child: at == null ? row : _out(at, row),
                        );
                      },
                    ),
                  ),
                ),
                // O recado de vazio abrindo no lugar da lista que fecha: as
                // duas alturas trocam na mesma curva, e o cartão só encolhe.
                if (settles)
                  SizeTransition(
                    sizeFactor: settle,
                    alignment: AlignmentDirectional.topStart,
                    child: FadeTransition(
                      opacity: settle.drive(CurveTween(curve: const Interval(0.4, 1))),
                      child: const _Empty(),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// O sino sem aviso nenhum. Um widget só pras duas portas -- a lista vazia e
/// o fim do "limpar tudo" --, que precisam ter a mesma altura: a troca de uma
/// pela outra acontece num frame e não pode pular.
class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
      child: Text(
        'Nenhuma notificação — quando um painel perguntar algo ou terminar, aparece aqui',
        style: TextStyle(fontSize: 12, color: Mx.fgFaint, height: 1.4),
      ),
    );
  }
}

/// A linha que sai pela direita e depois fecha o vão que deixou: primeiro o
/// movimento, que é o que o olho acompanha, depois a altura, que é o que
/// traz as de baixo pra cima.
class _Leaving extends StatefulWidget {
  const _Leaving({super.key, required this.leaving, required this.onGone, required this.child});

  /// Null enquanto fica; a espera antes de sair quando vai embora.
  final Duration? leaving;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_Leaving> createState() => _LeavingState();
}

class _LeavingState extends State<_Leaving> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this);
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    if (widget.leaving != null) WidgetsBinding.instance.addPostFrameCallback((_) => _go());
  }

  @override
  void didUpdateWidget(_Leaving old) {
    super.didUpdateWidget(old);
    if (old.leaving == null && widget.leaving != null) _go();
  }

  void _go() {
    if (!mounted || _wait != null || _c.isAnimating || _c.isCompleted) return;
    _c.duration = _motion(context, _slide);
    _wait = Timer(widget.leaving!, () {
      if (!mounted) return;
      _c.forward().whenComplete(() {
        if (mounted) widget.onGone();
      });
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final move = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.7, curve: Curves.easeInCubic),
    );
    final shrink = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.55, 1, curve: Curves.easeInOut),
    );
    return IgnorePointer(
      ignoring: widget.leaving != null,
      child: SizeTransition(
        sizeFactor: ReverseAnimation(shrink),
        alignment: AlignmentDirectional.topStart,
        child: FadeTransition(
          opacity: ReverseAnimation(move),
          child: SlideTransition(
            position: Tween(begin: Offset.zero, end: const Offset(1, 0)).animate(move),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Os cartões do sino na tela, empilhados no canto de baixo.
///
/// Guarda a própria lista em vez de desenhar [AppStore.toasts] direto: o
/// cartão que saiu do store ainda tem uma saída pra fazer, e ela só acontece
/// se ele continuar montado até o fim do deslize.
class NoticeToasts extends StatefulWidget {
  const NoticeToasts({super.key, required this.store});
  final AppStore store;

  @override
  State<NoticeToasts> createState() => _NoticeToastsState();
}

class _NoticeToastsState extends State<NoticeToasts> {
  final List<MxNotice> _shown = [];
  final Set<MxNotice> _leaving = {};

  @override
  void initState() {
    super.initState();
    _shown.addAll(widget.store.toasts);
    widget.store.addListener(_sync);
  }

  @override
  void didUpdateWidget(NoticeToasts old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_sync);
      widget.store.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final now = widget.store.toasts;
    var changed = false;
    for (final n in now) {
      if (!_shown.contains(n)) {
        _shown.add(n);
        changed = true;
      }
    }
    for (final n in _shown) {
      if (!now.contains(n) && _leaving.add(n)) changed = true;
    }
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // O mais novo perto do sino: embaixo com a barra no pé, em cima com ela
    // no topo.
    final top = widget.store.statusBarTop;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final n in top ? _shown.reversed : _shown)
          NoticeToast(
            // Pelo aviso, não pela posição: o cartão de cima sair não pode
            // reanimar os de baixo.
            key: ObjectKey(n),
            store: widget.store,
            notice: n,
            leaving: _leaving.contains(n),
            onGone: () => setState(() {
              _shown.remove(n);
              _leaving.remove(n);
            }),
          ),
      ],
    );
  }
}

/// Um aviso do sino na tela: a mesma linha da lista, num cartão só dela, no
/// canto de baixo -- o molde dos toasts do VS Code. Sai sozinho depois de
/// [AppStore.toastLife]; a linha fica no sino.
///
/// Entra deslizando pela direita, de fora da janela, e sai pelo mesmo lado.
/// A altura abre antes do deslize e fecha depois dele, então os cartões de
/// cima sobem e descem em vez de pular.
class NoticeToast extends StatefulWidget {
  const NoticeToast({
    super.key,
    required this.store,
    required this.notice,
    this.leaving = false,
    this.onGone,
  });
  final AppStore store;
  final MxNotice notice;
  final bool leaving;
  final VoidCallback? onGone;

  @override
  State<NoticeToast> createState() => _NoticeToastState();
}

class _NoticeToastState extends State<NoticeToast> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: _slide);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.duration = _motion(context, _slide);
    if (_c.isDismissed && !widget.leaving) _c.forward();
  }

  @override
  void didUpdateWidget(NoticeToast old) {
    super.didUpdateWidget(old);
    if (!old.leaving && widget.leaving) {
      _c.reverse().whenComplete(() {
        if (mounted) widget.onGone?.call();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = CurvedAnimation(
      parent: _c,
      curve: const Interval(0, 0.45, curve: Curves.easeOut),
    );
    final move = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.25, 1, curve: Curves.easeOutCubic),
      reverseCurve: const Interval(0.25, 1, curve: Curves.easeInCubic),
    );
    return IgnorePointer(
      ignoring: widget.leaving,
      child: SizeTransition(
        sizeFactor: size,
        alignment: AlignmentDirectional.topStart,
        // Sem isto o SizeTransition ocupa a largura inteira que recebe e
        // encosta o cartão na esquerda: a largura tem que ser a do cartão.
        fixedCrossAxisSizeFactor: 1,
        child: Padding(
          padding: widget.store.statusBarTop
              ? const EdgeInsets.only(top: 8)
              : const EdgeInsets.only(bottom: 8),
          child: SlideTransition(
            // Um pouco mais que a largura: a sombra também sai da vista.
            position: Tween(begin: const Offset(1.15, 0), end: Offset.zero).animate(move),
            child: FadeTransition(
              opacity: move,
              child: Container(
                width: NoticeCenter.width,
                decoration: BoxDecoration(
                  color: Mx.bgSidebar,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6)),
                  ],
                ),
                foregroundDecoration: _outline(),
                clipBehavior: Clip.antiAlias,
                child: _NoticeRow(
                  store: widget.store,
                  notice: widget.notice,
                  toast: true,
                  onDismiss: () => widget.store.dismissToast(widget.notice),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store, required this.onClear});
  final AppStore store;

  /// O "limpar tudo" passa pela lista, que é quem sabe fazer as linhas saírem.
  /// Null no meio de uma varrida: não há o que limpar duas vezes.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final any = store.notices.isNotEmpty;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Mx.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Notificações',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Mx.fg),
            ),
          ),
          // Aceso quando ligado: é um estado que dura, não uma ação que passa,
          // e precisa se ver de longe que está ligado.
          _SmallButton(
            icon: store.doNotDisturb
                ? Icons.notifications_off_rounded
                : Icons.notifications_off_outlined,
            tooltip: store.doNotDisturb
                ? 'Não perturbe ligado · os avisos não aparecem na tela'
                : 'Não perturbe · avisos só aqui, sem aparecer na tela',
            active: store.doNotDisturb,
            onTap: store.toggleDoNotDisturb,
          ),
          _SmallButton(
            icon: Icons.done_all_rounded,
            tooltip: 'Marcar tudo como lido',
            onTap: store.unreadNotices > 0 ? store.readAllNotices : null,
          ),
          _SmallButton(
            icon: Icons.clear_all_rounded,
            tooltip: 'Limpar tudo',
            onTap: any ? onClear : null,
          ),
          _SmallButton(
            icon: Icons.expand_more_rounded,
            tooltip: 'Fechar',
            onTap: store.closeNotices,
          ),
        ],
      ),
    );
  }
}

class _NoticeRow extends StatefulWidget {
  const _NoticeRow({
    required this.store,
    required this.notice,
    required this.onDismiss,
    this.toast = false,
  });
  final AppStore store;
  final MxNotice notice;

  /// O x. Quem monta a linha decide o que ele faz, porque é quem anima a
  /// saída: na lista, a linha desliza antes de sair do sino.
  final VoidCallback onDismiss;

  /// A linha dentro de um cartão na tela, e não na lista: o x tira só o
  /// cartão, e o ponteiro em cima segura o relógio dele. Ver [NoticeToast].
  final bool toast;

  @override
  State<_NoticeRow> createState() => _NoticeRowState();
}

class _NoticeRowState extends State<_NoticeRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.notice;
    final tab = widget.store.tabs.where((t) => t.id == n.tabId).firstOrNull;
    // O nome de agora, se o painel ainda existe: renomear depois do aviso
    // renomeia o aviso. Ver [MxNotice].
    final title = tab?.title ?? n.title;
    final gone = tab == null;
    final where = [
      if (tab != null && !tab.folder.isLoose) tab.folder.name,
      if (gone) 'painel fechado',
      shortAgo(n.at),
    ].join(' · ');

    return MouseRegion(
      cursor: gone ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hover = true);
        if (widget.toast) widget.store.holdToast(n, true);
      },
      onExit: (_) {
        setState(() => _hover = false);
        if (widget.toast) widget.store.holdToast(n, false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.store.openNotice(n),
        child: Container(
          color: _hover && !gone ? Mx.bgHover : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 1),
                decoration: BoxDecoration(
                  color: n.kind.color.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(n.kind.icon, size: 12, color: n.kind.color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Opacity(
                  opacity: gone ? 0.6 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: title,
                              style: TextStyle(fontWeight: FontWeight.w700, color: Mx.fg),
                            ),
                            TextSpan(text: ' ${n.kind.verb}'),
                          ],
                        ),
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: n.read ? Mx.fgDim : Mx.fg,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(where, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // O ponto de não lido e o x dividem o canto: o x só aparece sob
              // o ponteiro, que é quando a mão já está ali pra usá-lo.
              SizedBox(
                width: 22,
                height: 22,
                // No cartão o x fica sempre: é a saída dele, e um cartão que
                // só mostra como sair quando a mão chega parece preso.
                child: _hover || widget.toast
                    ? _SmallButton(
                        icon: Icons.close_rounded,
                        tooltip: widget.toast ? 'Tirar da tela' : 'Dispensar',
                        onTap: widget.onDismiss,
                      )
                    : n.read
                    ? null
                    : Center(
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(color: Mx.accent, shape: BoxShape.circle),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallButton extends StatefulWidget {
  const _SmallButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Um interruptor ligado: pinta na cor de destaque.
  final bool active;

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
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
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hover && enabled ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: !enabled
                  ? Mx.fgFaint.withValues(alpha: 0.5)
                  : widget.active
                  ? Mx.accent
                  : (_hover ? Mx.fg : Mx.fgDim),
            ),
          ),
        ),
      ),
    );
  }
}
