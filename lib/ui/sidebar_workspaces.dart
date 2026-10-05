part of 'sidebar.dart';

/// As pastas de um workspace, juntas e sob uma linha que dobra.
///
/// A linha junta, dobra, pinta e recebe pastas arrastadas. O que se abre, se
/// renomeia e se remove continua sendo da pasta, cada uma com o menu que ela
/// sempre teve. Ver [Workspace].
class _WorkspaceSection extends StatelessWidget {
  const _WorkspaceSection({super.key, required this.store, required this.workspace});

  final AppStore store;
  final Workspace workspace;

  @override
  Widget build(BuildContext context) {
    // Com uma busca em curso, só as pastas que ela achou -- e a seção dobrada
    // abre, como a pasta e a feature fazem.
    final folders = store
        .foldersOf(workspace)
        .where((f) => !store.filtering || store.hasHits(f))
        .toList();
    final collapsed = workspace.collapsed && !store.filtering;
    final count = store.foldersOf(workspace).length;
    final alerts = folders.fold<int>(0, (a, f) => a + store.needingHuman(f));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A seção inteira se arrasta por este cabeçalho, e é nele que uma
        // pasta solta entra no workspace -- no meio dele. Ver [_RowDrag].
        _RowDrag(
          store: store,
          place: (row: workspace, within: null),
          acceptsInto: true,
          child: InkWell(
            onTap: () => store.toggleWorkspaceCollapsed(workspace),
            onSecondaryTapDown: (d) =>
                showWorkspaceMenu(context, store, workspace, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 14, 8, 8),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 20,
                    color: Mx.fgDim,
                  ),
                  const SizedBox(width: 3),
                  // Nem o glifo de repo nem o da feature: um workspace não é um
                  // checkout e não é um trabalho com nome.
                  Icon(Icons.hexagon_outlined, size: 15, color: workspace.tint?.color ?? Mx.accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      workspace.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                  ),
                  // Fechada, a seção é a única linha que sobra de tudo que está
                  // lá dentro: o aviso de uma sessão parada tem que atravessar.
                  if (collapsed && alerts > 0) _Badge(count: alerts),
                  Text(
                    count == 1 ? '1 pasta' : '$count pastas',
                    style: TextStyle(color: Mx.fgFaint, fontSize: 11.5),
                  ),
                  _RowButton(
                    tooltip: 'O que fazer com esse workspace',
                    icon: Icons.more_horiz,
                    onTap: (anchor) => showWorkspaceMenu(context, store, workspace, anchor),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          _Nest(
            color: workspace.tint?.color,
            children: [
              for (final f in folders)
                _FolderGroup(
                  key: ValueKey('${workspace.id}/${f.root}'),
                  store: store,
                  folder: f,
                  within: workspace,
                ),
              // Vazio é um estado de verdade agora -- o workspace criado antes
              // dos repos, ou o que perdeu o último --, e a linha diz como sair
              // dele em vez de deixar um cabeçalho sobre nada.
              if (count == 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
                  child: Text(
                    'Arraste uma pasta pra cá',
                    style: TextStyle(color: Mx.fgFaint, fontSize: 11.5),
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ),
      ],
    );
  }
}

/// O que voa num arrasto de linha: de onde ela saiu, onde o ponteiro a pegou
/// e a altura em que o arrasto começou.
///
/// O ponto da pegada é o que deixa o cabeçalho de um workspace saber onde
/// está o ponteiro: o Flutter entrega ao alvo o canto do cartão no ar, e o
/// ponteiro é esse canto mais a pegada. A altura do começo diz de que lado a
/// linha veio, pra listra ficar do lado em que ela vai parar.
class RowDragData {
  RowDragData(this.from);
  final RowPlace from;
  Offset grab = Offset.zero;
  double startY = 0;
}

/// Arrasta uma linha da lateral -- pasta ou seção -- pra outro lugar.
///
/// É [_PanelDrag] um degrau acima: pega-se pelo cabeçalho, solta-se sobre
/// outra linha, e a linha em que se soltou é a vaga. O cabeçalho de um
/// workspace ([acceptsInto]) tem duas zonas: o meio é "entrar", e as bordas
/// são "ficar aqui do lado". Quem decide se pode é [AppStore.canDrop].
class _RowDrag extends StatefulWidget {
  const _RowDrag({
    required this.store,
    required this.place,
    this.acceptsInto = false,
    required this.child,
  });

  final AppStore store;
  final RowPlace place;
  final bool acceptsInto;
  final Widget child;

  @override
  State<_RowDrag> createState() => _RowDragState();
}

class _RowDragState extends State<_RowDrag> {
  /// O arrasto pairando sobre esta linha, quando é um que ela aceitaria.
  RowDragData? _incoming;

  /// Se o que paira vai entrar no workspace (meio do cabeçalho) em vez de
  /// ficar do lado.
  bool _into = false;

  bool _same(RowDragData d) =>
      identical(d.from.row, widget.place.row) && d.from.within == widget.place.within;

  /// O meio do cabeçalho: a metade de dentro da altura dele.
  bool _overMiddle(Offset pointer) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final y = box.globalToLocal(pointer).dy;
    return y > box.size.height * 0.25 && y < box.size.height * 0.75;
  }

  /// A listra embaixo quando a linha veio de cima e vai ficar na mesma faixa
  /// -- é onde [AppStore.moveRootRow] a põe. Vinda de outra faixa ela entra na
  /// vaga do alvo, e a listra fica em cima.
  bool get _stripeBelow {
    final d = _incoming!;
    if (d.from.within != widget.place.within) return false;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    return d.startY < box.localToGlobal(box.size.center(Offset.zero)).dy;
  }

  void _hover(RowDragData d, Offset feedbackTopLeft) {
    if (_same(d)) return;
    // Só uma pasta entra num workspace. Um workspace sobre o meio de outro
    // cabeçalho cai na zona de reordenar, senão o meio seria um buraco em que
    // o cartão some sem efeito. A pasta sobre o meio do próprio workspace
    // continua sem fazer nada, de propósito: soltá-la ali não a tira de lá.
    final into =
        widget.acceptsInto && d.from.row is Folder && _overMiddle(feedbackTopLeft + d.grab);
    final ok = widget.store.canDrop(d.from, widget.place, into: into);
    final incoming = ok ? d : null;
    final intoNow = ok && into;
    // O onMove chega a cada pixel do arrasto; redesenhar só quando muda.
    if (identical(incoming, _incoming) && intoNow == _into) return;
    setState(() {
      _incoming = incoming;
      _into = intoNow;
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = RowDragData(widget.place);
    return LayoutBuilder(
      builder: (context, box) => DragTarget<RowDragData>(
        onWillAcceptWithDetails: (d) =>
            _same(d.data) ||
            widget.store.canDrop(d.data.from, widget.place) ||
            (widget.acceptsInto && widget.store.canDrop(d.data.from, widget.place, into: true)),
        onMove: (d) => _hover(d.data, d.offset),
        onLeave: (_) {
          if (_incoming != null || _into) {
            setState(() {
              _incoming = null;
              _into = false;
            });
          }
        },
        onAcceptWithDetails: (d) {
          final into = _into;
          final accepted = _incoming;
          setState(() {
            _incoming = null;
            _into = false;
          });
          // Solta de volta em cima de si: um clique cujo ponteiro escorregou.
          if (_same(d.data)) return _toggle();
          if (accepted == null) return;
          widget.store.drop(d.data.from, widget.place, into: into);
        },
        builder: (context, _, _) => Stack(
          children: [
            Draggable<RowDragData>(
              data: data,
              dragAnchorStrategy: (draggable, context, position) {
                final anchor = childDragAnchorStrategy(draggable, context, position);
                data
                  ..grab = anchor
                  ..startY = position.dy;
                return anchor;
              },
              feedback: _lifted(widget.child, box.maxWidth),
              childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
              child: widget.child,
            ),
            if (_into)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Mx.accent.withValues(alpha: 0.12),
                      border: Border.all(color: Mx.accent, width: 1.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              )
            else if (_incoming != null)
              Positioned(
                left: 7,
                right: 7,
                top: _stripeBelow ? null : 0,
                bottom: _stripeBelow ? 0 : null,
                child: Container(
                  height: 2.5,
                  decoration: BoxDecoration(
                    color: Mx.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// O clique que o arrasto engoliu: dobrar a linha, que é o que o cabeçalho
  /// faz quando se clica nele.
  void _toggle() {
    final place = widget.place;
    if (place.row case final Folder f) widget.store.toggleFolderCollapsed(f, within: place.within);
    if (place.row case final Workspace w) widget.store.toggleWorkspaceCollapsed(w);
  }
}

/// O que dá pra fazer com um workspace. As pastas continuam com o menu delas;
/// este é o do conjunto.
Future<void> showWorkspaceMenu(
  BuildContext context,
  AppStore store,
  Workspace workspace,
  Offset anchor,
) async {
  final file = workspace.codeWorkspacePath;
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'Renomear…',
      ),
      tintItem(workspace.tint),
      mxDivider(),
      if (file == null)
        mxItem(
          'link',
          glyph: Icon(Icons.link, size: 14, color: Mx.fgDim),
          label: 'Associar .code-workspace…',
        )
      else ...[
        mxItem(
          'vscode',
          glyph: Icon(Icons.open_in_new, size: 14, color: Mx.fgDim),
          label: 'Abrir no vscode',
        ),
        mxItem(
          'unlink',
          glyph: Icon(Icons.link_off, size: 14, color: Mx.fgDim),
          label: 'Desassociar .code-workspace',
        ),
      ],
      mxDivider(),
      // Desfazer não fecha nada: as pastas voltam pra raiz. Fechar leva as
      // pastas só deste workspace e as sessões delas, e por isso pergunta.
      mxItem(
        'dissolve',
        glyph: Icon(Icons.hexagon_outlined, size: 14, color: Mx.fgDim),
        label: 'Desfazer workspace',
      ),
      mxItem(
        'close',
        glyph: Icon(Icons.folder_off_outlined, size: 14, color: Mx.red),
        label: 'Fechar workspace…',
        color: Mx.red,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'rename':
      final name = await promptText(
        context,
        title: 'Renomear workspace',
        initial: workspace.name,
        label: 'Nome',
      );
      if (name != null) store.renameWorkspace(workspace, name);
    case final pick when isTintChoice(pick):
      store.setWorkspaceTint(workspace, tintPicked(pick));
    case 'link':
      final picked = await Notifier.chooseWorkspace();
      if (picked.path case final path?) store.linkCodeWorkspace(workspace, path);
      if (!picked.available) store.showBanner('Não consegui abrir o seletor de arquivos', sticky: true);
    case 'vscode':
      await store.openInEditor(file!);
    case 'unlink':
      store.linkCodeWorkspace(workspace, null);
    case 'dissolve':
      final name = workspace.name;
      store.dissolveWorkspace(workspace);
      store.showBanner('Workspace "$name" desfeito — as pastas continuam na lateral');
    case 'close':
      await confirmCloseWorkspace(context, store, workspace);
  }
}
