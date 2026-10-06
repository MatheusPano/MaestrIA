import 'package:flutter/material.dart';

import '../models.dart';
import '../services/store.dart';
import '../theme.dart';
import 'dialogs.dart';

/// As tarefas que esta sessão sugeriu, num cartão no canto do terminal.
///
/// O par do cartão "tarefa sugerida" do Claude Desktop. Lá ele aparece no
/// meio do chat; aqui o chat é um pty, então o cartão flutua por cima dele, no
/// canto de baixo -- sem tirar linha nenhuma do terminal, que uma fita no
/// rodapé tirava (e cada linha a menos é um resize no pty). A mais nova na
/// frente, e as outras a um clique nas setas. Recolhido, vira um selo no mesmo
/// canto; uma sugestão nova o abre de novo. Só existe quando há alguma.
class SuggestionCard extends StatefulWidget {
  const SuggestionCard({super.key, required this.store, required this.tab});

  final AppStore store;
  final MxTab tab;

  static bool has(MxTab tab) => tab.hooks.suggestions.isNotEmpty;

  /// A distância do cartão até as bordas do terminal.
  static const inset = 12.0;

  static const width = 340.0;

  @override
  State<SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<SuggestionCard> {
  /// Na lista da mais nova pra mais velha: 0 é a que acabou de chegar.
  int _index = 0;
  bool _folded = false;

  /// Quantas havia no último build: uma a mais é uma sugestão nova, e ela
  /// merece ser vista mesmo com o cartão recolhido.
  int _seen = 0;

  @override
  Widget build(BuildContext context) {
    final pending = widget.tab.hooks.suggestions.reversed.toList();
    if (pending.length > _seen) {
      _folded = false;
      _index = 0;
    }
    _seen = pending.length;
    if (pending.isEmpty) return const SizedBox.shrink();
    _index = _index.clamp(0, pending.length - 1);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: _folded
          ? _FoldedBadge(
              key: const ValueKey('folded'),
              count: pending.length,
              onTap: () => setState(() => _folded = false),
            )
          : _Card(
              key: const ValueKey('card'),
              store: widget.store,
              tab: widget.tab,
              task: pending[_index],
              index: _index,
              count: pending.length,
              onStep: (step) => setState(() => _index = (_index + step) % pending.length),
              onFold: () => setState(() => _folded = true),
            ),
    );
  }
}

class _Card extends StatefulWidget {
  const _Card({
    super.key,
    required this.store,
    required this.tab,
    required this.task,
    required this.index,
    required this.count,
    required this.onStep,
    required this.onFold,
  });

  final AppStore store;
  final MxTab tab;
  final SuggestedTask task;
  final int index;
  final int count;
  final ValueChanged<int> onStep;
  final VoidCallback onFold;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  /// As outras formas de iniciar, abertas pela seta. Ver [_StartButton].
  bool _more = false;

  @override
  void didUpdateWidget(_Card old) {
    super.didUpdateWidget(old);
    // As opções eram da sugestão de antes: a seta do cartão vizinho não vem
    // aberta só porque a desta estava.
    if (old.task != widget.task) _more = false;
  }

  @override
  Widget build(BuildContext context) {
    final _Card(:store, :tab, :task, :index, :count, :onStep, :onFold) = widget;
    final canBranch = !tab.folder.isLoose;
    void go(SuggestionChoice choice) => actOnSuggestion(context, store, tab, task, choice);
    // O plugin que leva a sugestão a um tracker, se houver um ligado. Com o
    // switch dele ligado, toda saída cria a tarefa lá antes -- ver
    // [actOnSuggestion].
    final taker = store.suggestionTaker;
    final viaPlugin = taker != null && store.suggestionsToPlugin;
    return Container(
      constraints: const BoxConstraints(maxWidth: SuggestionCard.width),
      decoration: BoxDecoration(
        color: Mx.bgSidebar,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Mx.border),
        boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 6))],
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline_rounded, size: 13, color: Mx.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'tarefa sugerida',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, letterSpacing: 0.2, color: Mx.fgFaint),
                ),
              ),
              if (count > 1) ...[
                _CardIcon(
                  icon: Icons.chevron_left_rounded,
                  tooltip: 'a anterior',
                  onTap: () => onStep(-1),
                ),
                Text(
                  '${index + 1}/$count',
                  style: TextStyle(
                    fontSize: 11,
                    color: Mx.fgFaint,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                _CardIcon(
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'a próxima',
                  onTap: () => onStep(1),
                ),
                const SizedBox(width: 2),
              ],
              _CardIcon(icon: Icons.remove_rounded, tooltip: 'recolher', onTap: onFold),
              // O x do Desktop: descartar é a saída de quem leu e não quer, e
              // mora no canto pra não disputar a linha com os que iniciam.
              _CardIcon(
                icon: Icons.close_rounded,
                tooltip: 'descartar',
                onTap: () => actOnSuggestion(context, store, tab, task, SuggestionChoice.dismiss),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title.isEmpty ? 'tarefa sem título' : task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: Mx.fg,
                  ),
                ),
                if (task.tldr.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    task.tldr,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, height: 1.45, color: Mx.fgDim),
                  ),
                ],
              ],
            ),
          ),
          // As outras saídas, entre o resumo e os botões, e não num menu: o
          // cartão mora no pé do terminal, quase sempre encostado no pé da
          // janela, e um menu ali só tem pra onde abrir por cima do próprio
          // cartão. Aqui o cartão cresce pra cima -- ele é preso pela base --
          // e a seta que você acabou de clicar continua debaixo do ponteiro.
          AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: _more
                ? Padding(
                    padding: const EdgeInsets.only(top: 10, right: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(height: 1, color: Mx.border),
                        const SizedBox(height: 4),
                        if (canBranch)
                          _StartOption(
                            icon: Icons.terminal_rounded,
                            label: 'iniciar localmente',
                            detail: 'sessão nova nesta pasta, sem worktree',
                            onTap: () => go(SuggestionChoice.local),
                          ),
                        _StartOption(
                          icon: Icons.subdirectory_arrow_left_rounded,
                          label: 'fazer aqui',
                          detail: 'manda o prompt pra esta sessão',
                          onTap: () => go(SuggestionChoice.here),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (taker != null) ...[
            const SizedBox(height: 10),
            _PluginSwitch(
              label: taker.manifest!.suggestions!,
              on: store.suggestionsToPlugin,
              onChanged: store.setSuggestionsToPlugin,
            ),
          ],
          SizedBox(height: taker != null ? 6 : 12),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            // Um Wrap, e não uma linha: num painel estreito os botões descem
            // em vez de estourar o cartão.
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              runSpacing: 4,
              children: [
                Tooltip(
                  message: 'o cartão inteiro, com o prompt da sessão nova',
                  child: TextButton(
                    style: _compact(foreground: Mx.fgDim),
                    onPressed: () => showSuggestion(context, store, tab, task),
                    child: const Text('detalhes'),
                  ),
                ),
                _StartButton(
                  canBranch: canBranch,
                  open: _more,
                  tooltip: !viaPlugin
                      ? null
                      : canBranch
                      ? 'cria a tarefa no ${taker.name}, a worktree dela e abre a sessão'
                      : 'cria a tarefa no ${taker.name} e abre a sessão nesta pasta',
                  onStart: () => go(canBranch ? SuggestionChoice.worktree : SuggestionChoice.local),
                  onMore: () => setState(() => _more = !_more),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Botões do tamanho do cartão: os do Material têm 40 de altura e texto de
  /// 14, feitos pra um diálogo e não pra um canto de painel.
  static ButtonStyle _compact({Color? foreground}) => _compactStyle(foreground: foreground);
}

ButtonStyle _compactStyle({Color? foreground, BorderRadius? radius}) => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  visualDensity: VisualDensity.compact,
  textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: radius ?? BorderRadius.circular(6)),
  ),
  foregroundColor: foreground == null ? null : WidgetStatePropertyAll(foreground),
);

/// O botão de iniciar, partido em dois como o do Desktop: a saída de sempre na
/// frente, e a seta com as outras -- iniciar sem worktree, ou fazer aqui --,
/// que abrem dentro do cartão. Ver [_CardState._more].
///
/// Partido e não três botões lado a lado: num cartão de 340px os três não
/// cabem numa linha, e a pergunta que o cartão faz é "começar ou não"; *onde*
/// é o detalhe que a seta guarda.
class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.canBranch,
    required this.open,
    this.tooltip,
    required this.onStart,
    required this.onMore,
  });

  /// Worktree é coisa de repositório: nos avulsos a saída da frente é a
  /// sessão nova na mesma pasta, e a seta fica só com o "fazer aqui".
  final bool canBranch;
  final bool open;

  /// O que a metade da frente faz, quando não é o de sempre -- com o switch
  /// do plugin ligado, quem cria a tarefa e a worktree é ele.
  final String? tooltip;
  final VoidCallback onStart;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(6);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Flexível, e com reticências: num painel estreito a metade da frente
        // encolhe, e a seta -- que é a porta das outras -- fica inteira.
        Flexible(
          child: Tooltip(
            message:
                tooltip ??
                (canBranch
                    ? 'pede o id da task, cria a worktree e abre a sessão nela'
                    : 'sessão nova nesta mesma pasta'),
            child: FilledButton(
              style: _compactStyle(radius: const BorderRadius.horizontal(left: r)),
              onPressed: onStart,
              child: Text(
                canBranch ? 'iniciar com worktree' : 'iniciar localmente',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        // O vão de um pixel é o risco entre as duas metades: o fundo do
        // cartão aparecendo, e não uma cor a mais pra combinar com o tema.
        const SizedBox(width: 1),
        Tooltip(
          message: open ? 'esconder as outras formas' : 'outras formas de iniciar',
          child: FilledButton(
            style: _compactStyle(
              radius: const BorderRadius.horizontal(right: r),
            ).copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6))),
            onPressed: onMore,
            // Pra cima, que é pra onde as opções abrem; virada, fecha.
            child: AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 160),
              child: const Icon(Icons.expand_less_rounded, size: 16),
            ),
          ),
        ),
      ],
    );
  }
}

/// O switch do plugin que leva a sugestão a um tracker: "criar a task no
/// Wiboor". Ver [AppStore.suggestionsToPlugin].
///
/// A linha inteira é o alvo, e não só a bolinha: um switch de 28px num canto
/// de painel é um alvo que se erra.
class _PluginSwitch extends StatelessWidget {
  const _PluginSwitch({required this.label, required this.on, required this.onChanged});

  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(!on),
          child: Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: on ? Mx.fg : Mx.fgDim),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 20,
                  child: FittedBox(
                    child: Switch(
                      value: on,
                      onChanged: onChanged,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Uma das outras formas de iniciar: o nome, e embaixo, apagado, onde a
/// sessão vai rodar -- que é a diferença inteira entre as duas.
class _StartOption extends StatefulWidget {
  const _StartOption({
    required this.icon,
    required this.label,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final VoidCallback onTap;

  @override
  State<_StartOption> createState() => _StartOptionState();
}

class _StartOptionState extends State<_StartOption> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
          decoration: BoxDecoration(
            color: _hover ? Mx.bgHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: _hover ? Mx.accent : Mx.fgFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: Mx.fg),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      widget.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Mx.fgFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Um ícone do cabeçalho do cartão: quadradinho que acende no hover.
class _CardIcon extends StatefulWidget {
  const _CardIcon({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_CardIcon> createState() => _CardIconState();
}

class _CardIconState extends State<_CardIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, size: 15, color: _hover ? Mx.fg : Mx.fgFaint),
          ),
        ),
      ),
    );
  }
}

/// O cartão recolhido: a lâmpada e quantas há, no mesmo canto.
class _FoldedBadge extends StatefulWidget {
  const _FoldedBadge({super.key, required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  State<_FoldedBadge> createState() => _FoldedBadgeState();
}

class _FoldedBadgeState extends State<_FoldedBadge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.count;
    return Tooltip(
      message: n == 1 ? 'mostrar a tarefa sugerida' : 'mostrar as $n tarefas sugeridas',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Mx.bgSidebar,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Mx.accent.withValues(alpha: 0.45)),
              boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 10, offset: const Offset(0, 3))],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lightbulb_outline_rounded, size: 13, color: Mx.accent),
                const SizedBox(width: 6),
                Text(
                  n == 1 ? '1 sugestão' : '$n sugestões',
                  style: TextStyle(fontSize: 11.5, color: _hover ? Mx.fg : Mx.fgDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// O cartão de uma sugestão: título, resumo, o prompt inteiro se você quiser
/// ler, e as saídas.
Future<void> showSuggestion(
  BuildContext context,
  AppStore store,
  MxTab tab,
  SuggestedTask task,
) async {
  // O context de quem chamou pode não durar o cartão: a linha do sino some
  // assim que a lista fecha, e a ficha do rodapé, quando a fila muda. O do
  // navigator dura a janela inteira, e é ele que a caixa do id vai precisar
  // depois que o cartão fechar.
  final host = Navigator.of(context).context;
  // Worktree é coisa de repositório: a bandeja dos avulsos não tem de onde
  // tirar uma.
  final canBranch = !tab.folder.isLoose;
  final choice = await showDialog<SuggestionChoice>(
    context: host,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
      title: Row(
        children: [
          Icon(Icons.lightbulb_outline_rounded, size: 14, color: Mx.accent),
          const SizedBox(width: 8),
          Text('tarefa sugerida por ${tab.title}', style: TextStyle(fontSize: 12, color: Mx.fgDim)),
          const Spacer(),
          IconButton(
            tooltip: 'fechar',
            iconSize: 16,
            onPressed: () => Navigator.pop(ctx),
            icon: Icon(Icons.close, color: Mx.fgDim),
          ),
        ],
      ),
      content: SizedBox(width: 560, child: _SuggestionBody(task: task)),
      // Soltos, e não num `Row`: as `actions` vão pra um `OverflowBar`, que
      // empilha os botões quando a janela não comporta os quatro numa linha.
      // Um `Row` dentro dele não encolhe e estoura.
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, SuggestionChoice.dismiss),
          child: Text('descartar', style: TextStyle(color: Mx.fgDim)),
        ),
        Tooltip(
          message: 'manda o prompt pra esta sessão, como o próximo pedido',
          child: TextButton(
            onPressed: () => Navigator.pop(ctx, SuggestionChoice.here),
            child: const Text('fazer aqui'),
          ),
        ),
        Tooltip(
          message: 'sessão nova nesta mesma pasta, sem worktree',
          child: TextButton(
            onPressed: () => Navigator.pop(ctx, SuggestionChoice.local),
            child: const Text('iniciar localmente'),
          ),
        ),
        Tooltip(
          message: canBranch
              ? 'pede o id da task, cria a worktree e abre a sessão nela'
              : 'avulsos não têm repositório pra tirar uma worktree',
          child: FilledButton(
            onPressed: canBranch ? () => Navigator.pop(ctx, SuggestionChoice.worktree) : null,
            child: const Text('iniciar com worktree'),
          ),
        ),
      ],
    ),
  );
  if (choice == null || !host.mounted) return;
  await actOnSuggestion(host, store, tab, task, choice);
}

/// Faz [choice] com [task]: o que os botões do cartão e os do diálogo
/// disparam.
Future<void> actOnSuggestion(
  BuildContext context,
  AppStore store,
  MxTab tab,
  SuggestedTask task,
  SuggestionChoice choice,
) async {
  final host = Navigator.of(context).context;

  // A sugestão pode ter sido retirada pela sessão enquanto o cartão estava
  // aberto: aí ela não é mais de ninguém, e começar agora seria fazer algo
  // que a própria sessão disse que não precisa mais.
  if (!tab.hooks.suggestions.contains(task)) {
    store.showBanner('a sessão retirou essa sugestão enquanto o cartão estava aberto');
    return;
  }

  // Com o switch do tracker ligado, toda saída cria a tarefa lá primeiro: o
  // plugin abre o formulário, e só quando a tarefa existe a Maestria faz o
  // que foi escolhido aqui, já com o número dela. Ver
  // [AppStore.startSuggestionInPlugin].
  final taker = store.suggestionTaker;
  if (choice != SuggestionChoice.dismiss && taker != null && store.suggestionsToPlugin) {
    await store.startSuggestionInPlugin(taker, tab, task, choice);
    return;
  }

  switch (choice) {
    case SuggestionChoice.dismiss:
      store.dismissSuggestion(tab, task);
    case SuggestionChoice.here:
      await store.runSuggestionHere(tab, task);
    case SuggestionChoice.local:
      store.startSuggestionHere(tab, task);
    case SuggestionChoice.worktree:
      final opened = await showNewTask(
        host,
        store,
        tab.folder,
        featureOrHotfix: store.featureOrHotfixOf(tab),
        prompt: task.prompt,
        heading: task.title.isEmpty ? null : 'Nova task: ${task.title}',
      );
      // Cancelou o id, ou a worktree não saiu: a sugestão continua de pé.
      if (opened != null) store.startedSuggestion(tab, task);
  }
}

class _SuggestionBody extends StatefulWidget {
  const _SuggestionBody({required this.task});
  final SuggestedTask task;

  @override
  State<_SuggestionBody> createState() => _SuggestionBodyState();
}

class _SuggestionBodyState extends State<_SuggestionBody> {
  /// O prompt fica dobrado: o que se lê pra decidir é o resumo, e o prompt é
  /// o que você abre quando quer saber exatamente o que vai ser pedido.
  bool _prompt = false;

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          task.title.isEmpty ? 'tarefa sem título' : task.title,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Mx.fg),
        ),
        if (task.tldr.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(task.tldr, style: TextStyle(fontSize: 13, height: 1.45, color: Mx.fgDim)),
        ],
        const SizedBox(height: 12),
        InkWell(
          onTap: () => setState(() => _prompt = !_prompt),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_prompt ? Icons.expand_less : Icons.expand_more, size: 14, color: Mx.fgFaint),
                const SizedBox(width: 4),
                Text(
                  _prompt ? 'esconder o prompt' : 'ver o prompt da sessão nova',
                  style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
                ),
              ],
            ),
          ),
        ),
        if (_prompt)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: Mx.bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Mx.border),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                task.prompt,
                style: TextStyle(fontSize: 12, height: 1.45, fontFamily: Mx.mono, color: Mx.fg),
              ),
            ),
          ),
      ],
    );
  }
}
