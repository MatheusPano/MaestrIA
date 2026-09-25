import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/store.dart';
import '../theme.dart';

/// O grupo de toque do sino: o botão e a lista contam como um lugar só, então
/// clicar no botão com a lista aberta fecha pelo botão -- e não fecha pelo
/// "clicou fora" pra reabrir logo em seguida pelo botão.
const noticeTapGroup = #mxNotices;

/// A faixa no pé da janela, no molde da barra de status do VS Code: o resumo
/// das sessões à esquerda e o sino na ponta direita.
///
/// No canvas e sem borda: é a moldura da janela, não mais um cartão. A altura
/// que ela ocupa é fixa -- nada nela aparece ou some a ponto de mudar o
/// tamanho dos painéis, e é isso que a deixa morar fora do [Stack] dos
/// recados: o tamanho do pty não depende do que ela diz.
class StatusBar extends StatelessWidget {
  const StatusBar({super.key, required this.store});
  final AppStore store;

  static const height = 26.0;

  @override
  Widget build(BuildContext context) {
    final claude = store.tabs.where((t) => t.kind == TabKind.claude && !t.exited).toList();
    final working = claude
        .where((t) => t.status == ClaudeStatus.working || t.status == ClaudeStatus.tool)
        .length;
    final waiting = claude.where((t) => !t.done && t.status.needsHuman).length;
    return SizedBox(
      height: height,
      child: Padding(
        // Centrar na conta não centra no olho: em cima da barra está a borda
        // dos cartões, embaixo está a borda da janela, e o vão de cima lia
        // maior. Os 3px a mais embaixo sobem o conteúdo pro meio que se vê.
        padding: const EdgeInsets.fromLTRB(Mx.gap + 4, 0, Mx.gap + 4, 3),
        child: Row(
          children: [
            Expanded(
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
                style: TextStyle(fontSize: 11.5, height: 1, color: Mx.fgFaint),
              ),
            ),
            NoticeBell(store: store),
          ],
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
          'notificações',
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
const _cascade = Duration(milliseconds: 45);

/// Zero quando o sistema pede menos movimento: o aviso aparece e some igual,
/// só que sem viagem.
Duration _motion(BuildContext context, Duration d) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false ? Duration.zero : d;

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

class _NoticeCenterState extends State<NoticeCenter> {
  /// As linhas saindo, e quanto cada uma espera pra começar. A linha só sai
  /// do sino quando a animação dela termina -- ver [_Leaving].
  final Map<MxNotice, Duration> _leaving = {};

  /// A rede do "limpar tudo": a lista só monta as linhas que cabem na vista,
  /// e as de baixo, que nunca foram desenhadas, nunca terminariam de sair.
  Timer? _sweep;

  @override
  void dispose() {
    _sweep?.cancel();
    super.dispose();
  }

  void _dismiss(MxNotice n) => setState(() => _leaving[n] = Duration.zero);

  void _clearAll() {
    final all = List.of(widget.store.notices);
    setState(() {
      for (final (i, n) in all.indexed) {
        _leaving.putIfAbsent(n, () => _cascade * i.clamp(0, 10));
      }
    });
    _sweep?.cancel();
    _sweep = Timer(_motion(context, _slide) + _cascade * 10, () {
      for (final n in all) {
        _gone(n);
      }
    });
  }

  void _gone(MxNotice n) {
    _leaving.remove(n);
    if (widget.store.notices.contains(n)) widget.store.dismissNotice(n);
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final notices = store.notices;
    return TapRegion(
      groupId: noticeTapGroup,
      onTapOutside: (_) => store.closeNotices(),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, 8 * (1 - t)), child: child),
        ),
        child: Container(
          width: NoticeCenter.width,
          constraints: const BoxConstraints(maxHeight: 420),
          decoration: BoxDecoration(
            color: Mx.bgSidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Mx.accent.withValues(alpha: 0.7)),
            boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(store: store, onClear: _clearAll),
              if (notices.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
                  child: Text(
                    'nenhuma notificação — quando um painel perguntar algo ou terminar, aparece aqui',
                    style: TextStyle(fontSize: 12, color: Mx.fgFaint, height: 1.4),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 4),
                    itemCount: notices.length,
                    itemBuilder: (_, i) {
                      final n = notices[i];
                      // O divisor vai dentro da linha, e não entre elas: uma
                      // linha que encolhe até sumir leva o traço dela junto.
                      return _Leaving(
                        key: ObjectKey(n),
                        leaving: _leaving[n],
                        onGone: () => _gone(n),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (i > 0) Divider(height: 1, thickness: 1, color: Mx.border),
                            _NoticeRow(store: store, notice: n, onDismiss: () => _dismiss(n)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final n in _shown)
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
          padding: const EdgeInsets.only(bottom: 8),
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
                  border: Border.all(color: Mx.accent.withValues(alpha: 0.7)),
                  boxShadow: [
                    BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6)),
                  ],
                ),
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
  final VoidCallback onClear;

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
                ? 'não perturbe ligado · os avisos não aparecem na tela'
                : 'não perturbe · avisos só aqui, sem aparecer na tela',
            active: store.doNotDisturb,
            onTap: store.toggleDoNotDisturb,
          ),
          _SmallButton(
            icon: Icons.done_all_rounded,
            tooltip: 'marcar tudo como lido',
            onTap: store.unreadNotices > 0 ? store.readAllNotices : null,
          ),
          _SmallButton(
            icon: Icons.clear_all_rounded,
            tooltip: 'limpar tudo',
            onTap: any ? onClear : null,
          ),
          _SmallButton(
            icon: Icons.expand_more_rounded,
            tooltip: 'fechar',
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
                        tooltip: widget.toast ? 'tirar da tela' : 'dispensar',
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
