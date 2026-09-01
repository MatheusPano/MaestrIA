import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'dialogs.dart';
import 'panel.dart';
import 'panes.dart';
import 'settings.dart';
import 'terminal_pane.dart';

/// Folders, each with its panels underneath. The shape of the whole app.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    // The width is the parent's to decide: the gutter beside it is a drag
    // handle, and AppStore.sidebarWidth is what it drags.
    return MxPanel(
      color: Mx.bgSidebar,
      child: Column(
        children: [
          _Header(store: store),
          Expanded(
            // The loose tray closes the list on purpose: it is where you go
            // when none of the folders above is the answer.
            child: ListView(
              padding: const EdgeInsets.only(top: 6, bottom: 20),
              children: [
                if (store.folders.isEmpty && !store.filtering) _NoFolders(),
                if (store.filtering && store.hits.isEmpty) _NoHits(store: store),
                // Keyed by what the row *is*, so a list that gains, loses or
                // reorders an entry moves the rows instead of repainting one
                // row's content into another's place -- which is what a
                // hovered row swapping under the pointer looked like.
                //
                // Com uma busca em curso, um grupo sem achado nenhum sai
                // inteiro: o cabeçalho dele seria uma linha dizendo "não é
                // aqui" no lugar de uma que é.
                for (final p in store.folders)
                  if (!store.filtering || store.hasHits(p))
                    _FolderGroup(key: ValueKey(p.root), store: store, folder: p),
                if (!store.filtering || store.hasHits(store.loose))
                  _LooseTray(key: const ValueKey('loose'), store: store),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// O endereço do campo de busca, pra quem está fora da lateral.
///
/// Existe um só — a lateral é uma — e o atalho precisa de um lugar pra mandar
/// o foco. Um [FocusNode] guardado no store seria estado de widget morando num
/// serviço; aqui ele mora no arquivo do widget que o usa.
class SidebarSearch {
  const SidebarSearch._();

  static final FocusNode focus = FocusNode(debugLabel: 'busca da lateral');

  static void reveal() => focus.requestFocus();
}

class _Header extends StatelessWidget {
  const _Header({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    // No name and no count up here on purpose. The window title already says
    // which app this is, and the number of folders is the list right below —
    // both were the header repeating what the user could already see. Same 42
    // as a panel header, so the two top edges line up across the window.
    //
    // O que a faixa carrega agora é a busca, e ela leva a largura toda: com
    // dez, vinte sessões abertas, achar *aquela* que você renomeou era rolar a
    // lista com o olho. Adicionar uma pasta é uma vez por repo e configurar é
    // menos que isso — os dois cabem num glifo à direita, que é para onde o +
    // foi. A regra de antes era "o que adiciona à esquerda"; a nova é "o que
    // você faz toda hora à esquerda".
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Mx.border)),
      ),
      child: LayoutBuilder(
        // Estreita, a lateral não tem espaço pra palavra "pasta" e pro campo
        // ao mesmo tempo — e é o campo que fica. O tooltip continua dizendo o
        // que o + adiciona.
        builder: (context, box) {
          final tight = box.maxWidth < 300;
          return Row(
            children: [
              Expanded(child: _SearchField(store: store)),
              const SizedBox(width: 6),
              _HeaderAction(
                icon: Icons.add,
                label: tight ? null : 'pasta',
                tooltip: 'adicionar uma pasta ao cockpit',
                onPressed: () => showAddFolder(context, store),
              ),
              _HeaderIcon(
                icon: Icons.tune,
                // A tecla vem do mapa e não de um literal: ela é editável agora, e
                // um tooltip que ensinasse ⌘⇧P a quem trocou por outra estaria
                // simplesmente errado.
                tooltip: ['configurações', ...store.keymap[MxAction.settings].map((c) => c.label)]
                    .join('  '),
                onPressed: () => showSettings(context, store),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// O campo de busca da lateral, com o filtro montado dentro dele.
///
/// O filtro mora aqui e não do lado por uma razão: ele é a outra metade da
/// mesma pergunta. "Qual sessão?" se responde escrevendo o nome ou apontando
/// o lugar — repo, projeto, estado — e as duas metades esvaziam pelo mesmo x.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.store});
  final AppStore store;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.store.query;
    SidebarSearch.focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(_SearchField old) {
    super.didUpdateWidget(old);
    // O store é quem manda: o x, o "limpar filtros" e o Esc chamam
    // `clearSearch`, e o campo tem que seguir sem que cada um deles saiba que
    // existe um controller aqui.
    if (widget.store.query != _controller.text) _controller.text = widget.store.query;
  }

  @override
  void dispose() {
    SidebarSearch.focus.removeListener(_onFocus);
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = SidebarSearch.focus.hasFocus);
  }

  void _escape() {
    // Esc com texto limpa; Esc no campo já vazio devolve o teclado ao painel,
    // que é o que ele faz em qualquer outro lugar do app.
    if (widget.store.filtering) {
      widget.store.clearSearch();
    } else {
      SidebarSearch.focus.unfocus();
    }
  }

  /// Como se chega aqui pelo teclado, se ainda houver tecla pra isso: o mapa é
  /// editável, e quem tirou o atalho não deve ler que ele existe.
  String get _chord {
    final keys = widget.store.keymap[MxAction.search];
    return keys.isEmpty ? '' : '  ${keys.first.label}';
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final has = store.query.isNotEmpty;

    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        color: _focused ? Mx.bgActive : Mx.bgHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _focused ? Mx.accent : Mx.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: _focused ? Mx.fgDim : Mx.fgFaint),
          const SizedBox(width: 6),
          Expanded(
            child: Shortcuts(
              // Antes do TextField, senão o Esc morre nele.
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.escape): _ClearIntent(),
              },
              child: Actions(
                actions: {
                  _ClearIntent: CallbackAction<_ClearIntent>(
                    onInvoke: (_) {
                      _escape();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  controller: _controller,
                  focusNode: SidebarSearch.focus,
                  onChanged: store.setQuery,
                  cursorColor: Mx.accent,
                  cursorWidth: 1.5,
                  style: TextStyle(fontSize: 12, color: Mx.fg),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    // A tecla vai no próprio hint, lida do mapa: é o único
                    // lugar onde ela se ensina sem custar uma linha de tela, e
                    // ela sai da frente no instante em que o campo é usado.
                    hintText: _focused ? 'buscar sessão' : 'buscar sessão$_chord',
                    hintStyle: TextStyle(fontSize: 12, color: Mx.fgFaint),
                  ),
                ),
              ),
            ),
          ),
          if (has)
            _MiniButton(
              icon: Icons.close_rounded,
              tooltip: 'limpar a busca',
              onTap: () {
                store.setQuery('');
                _controller.clear();
              },
            ),
          _FilterButton(store: store),
        ],
      ),
    );
  }
}

/// O que o Esc faz dentro do campo. Ver [_SearchFieldState._escape].
class _ClearIntent extends Intent {
  const _ClearIntent();
}

/// O glifo de filtro no canto do campo, e o menu que ele abre.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final active = store.activeFilters;
    return _MiniButton(
      icon: Icons.filter_list_rounded,
      tooltip: active == 0
          ? 'filtrar por pasta, projeto ou estado'
          : '$active ${active == 1 ? 'filtro' : 'filtros'} — clique pra mexer',
      // O ponto é o que diz, com o menu fechado, que a lista na sua frente não
      // é a lista inteira. Sem ele, um filtro esquecido é uma sessão que
      // "desapareceu".
      lit: active > 0,
      onTapAt: (anchor) => showFilterMenu(context, store, anchor),
    );
  }
}

/// Um alvo de 22px pra dentro do campo de busca: menor que um [_RowButton],
/// porque ele divide os 28px de altura do campo com o texto.
class _MiniButton extends StatefulWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.onTapAt,
    this.lit = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Quando o clique abre um menu: diz onde o glifo está, pro menu nascer sob
  /// ele. Um dos dois é obrigatório.
  final void Function(Offset anchor)? onTapAt;
  final bool lit;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.lit ? Mx.accent : (_hover ? Mx.fg : Mx.fgFaint);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Builder(
          builder: (ctx) => GestureDetector(
            onTap: () {
              if (widget.onTap != null) return widget.onTap!();
              final box = ctx.findRenderObject() as RenderBox?;
              widget.onTapAt?.call(
                box == null ? Offset.zero : box.localToGlobal(box.size.bottomLeft(Offset.zero)),
              );
            },
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: _hover ? Mx.border : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(widget.icon, size: 14, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled button in the sidebar header. Low-key by default and lit on
/// hover: it is an action, not an ornament, but it is not the loudest thing
/// on the screen either — the panels are.
class _HeaderAction extends StatefulWidget {
  const _HeaderAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;

  /// Null numa lateral estreita: sobra o + e o tooltip. Ver [_Header].
  final String? label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: _hover ? Mx.bgHover : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _hover ? Mx.border : Colors.transparent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 15, color: _hover ? Mx.fg : Mx.fgDim),
                if (widget.label case final label?) ...[
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _hover ? Mx.fg : Mx.fgDim,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The icon-only half of the header: the switches that change how the sidebar
/// and the panes are *shown*, kept together on the right and sized alike so
/// the group reads as one control cluster.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 17,
      splashRadius: 15,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: Mx.fgDim),
      onPressed: onPressed,
    );
  }
}

/// A folder and everything under it. Never the loose tray — that is
/// [_LooseTray], which is not a folder and stopped pretending to be one.
class _FolderGroup extends StatelessWidget {
  const _FolderGroup({super.key, required this.store, required this.folder});
  final AppStore store;
  final Folder folder;

  @override
  Widget build(BuildContext context) {
    // Panels that belong to a project are drawn inside it, not twice. Com uma
    // busca em curso é só o que ela achou -- e um projeto sem achado sai junto.
    final projects = store
        .projectsOf(folder)
        .where((p) => !store.filtering || store.visible(store.tabsIn(p)).isNotEmpty)
        .toList();
    final tabs = store.visible(store.tabsOf(folder).where((t) => t.projectId == null));
    final all = store.worktrees[folder.root] ?? const <WorktreeInfo>[];
    // Only the repo's own worktrees. Claude Code keeps transient ones under
    // ~/.local/state, and offering to do anything to one of those is offering
    // something that fails: they belong to the session that made them.
    // As worktrees saem de cena durante uma busca: são o que o repo *é*, não
    // uma sessão que você esteja procurando, e a lista de resultados não
    // precisa de uma gaveta de material de referência no meio dela.
    final worktrees = store.filtering
        ? const <WorktreeInfo>[]
        : all.where((w) => w.path.startsWith(folder.root)).toList();
    final alerts = store.needingHuman(folder);
    // Dobrada, uma pasta esconderia o que a busca acabou de achar nela. O que
    // você escolheu continua guardado -- só não vale enquanto se procura.
    final collapsed = folder.collapsed && !store.filtering;
    final count = store.filtering
        ? store.visible(store.tabsOf(folder)).length
        : store.tabsOf(folder).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The + rides on the header instead of a strip of chips under every
        // folder: one target per row, and what it can start is in its menu.
        _Hoverable(
          builder: (hovered) => InkWell(
            onTap: () => store.toggleCollapsed(folder),
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
                  RepoGlyph(isRepo: folder.isRepo),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folder.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        // Which branch the checkout itself is parked on. With the
                        // worktrees folded away below, this is the line that says
                        // what cd-ing into the folder would actually give you.
                        if (folder.branch.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.call_split, size: 10, color: Mx.fgFaint),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  folder.branch,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: Mx.mono,
                                    fontSize: 10.5,
                                    color: Mx.fgFaint,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (alerts > 0) _Badge(count: alerts),
                  Text('$count', style: TextStyle(color: Mx.fgFaint, fontSize: 11.5)),
                  _AddButton(
                    store: store,
                    folder: folder,
                    // An empty folder has no rows to hover over, so the + is
                    // the only thing left to aim at: it stays out.
                    shown: hovered || store.tabsOf(folder).isEmpty,
                  ),
                  _FolderMenu(store: store, folder: folder),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          _Nest(
            children: [
              // Worktrees first, folded, and always in the same place: what a
              // repo *is* comes before what happens to be running in it. Under
              // the sessions the line moved every time a panel opened or
              // closed, so the one row that is meant to be a fixed landmark
              // was the one row you had to hunt for.
              _WorktreeFolder(store: store, folder: folder, worktrees: worktrees),
              for (final p in projects)
                _ProjectGroup(key: ValueKey(p.id), store: store, folder: folder, project: p),
              for (final t in tabs) _TabRow(key: ValueKey(t.id), store: store, tab: t),
              // The strip of chips used to end the nest; the rail still wants
              // to run a little past the last row rather than stop dead on it.
              const SizedBox(height: 8),
            ],
          ),
      ],
    );
  }
}

/// The panels that belong to no folder: a rule across the sidebar with a word
/// on it, and the rows flush underneath at the top level.
///
/// It used to be drawn as a [_FolderGroup] — chevron, folder glyph, ⋯ menu,
/// rows on a rail — and every one of those said something untrue. There is no
/// directory called "avulsos", nothing to fold away into, nothing the rows are
/// *inside*. What is actually true is only that the folders have run out and
/// these are what is left, and a divider says that and nothing more.
class _LooseTray extends StatelessWidget {
  const _LooseTray({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final folder = store.loose;
    final tabs = store.visible(store.tabsOf(folder).where((t) => t.projectId == null));
    final alerts = store.needingHuman(folder);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hoverable(
          builder: (hovered) => Padding(
            // Air above, close below: the gap is what separates the tray from
            // the last folder, and the label has to read as belonging to the
            // rows it introduces rather than floating between the two.
            padding: EdgeInsets.only(left: 17, right: 8, top: store.folders.isEmpty ? 4 : 22),
            child: Row(
              children: [
                Text(
                  folder.name,
                  style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, letterSpacing: 0.5),
                ),
                const SizedBox(width: 9),
                Expanded(child: Container(height: 1, color: Mx.border)),
                // The count earns its place only once there is something to
                // count -- an empty tray is a divider and a + , and a "0"
                // beside them is one mark more than the tray is worth.
                if (alerts > 0) ...[const SizedBox(width: 8), _Badge(count: alerts)],
                if (tabs.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('${tabs.length}', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                ],
                const SizedBox(width: 6),
                _AddButton(store: store, folder: folder, shown: hovered || tabs.isEmpty),
                _LooseMenu(store: store),
              ],
            ),
          ),
        ),
        for (final t in tabs) _TabRow(key: ValueKey(t.id), store: store, tab: t),
      ],
    );
  }
}

/// The one thing you can do to the tray as a whole. A [_FolderMenu] would
/// have brought a folder's worth of options — rename, remove, git — to a place
/// where none of them mean anything.
class _LooseMenu extends StatelessWidget {
  const _LooseMenu({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return _RowButton(
      tooltip: 'o que fazer com os avulsos',
      icon: Icons.more_horiz,
      onTap: (anchor) async {
        final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
        final choice = await showMenu<String>(
          context: context,
          color: Mx.bgActive,
          position: RelativeRect.fromRect(anchor & Size.zero, Offset.zero & overlay.size),
          items: const [
            PopupMenuItem(
              value: 'sweep',
              height: 34,
              child: Text('limpar encerrados e concluídos', style: TextStyle(fontSize: 12)),
            ),
          ],
        );
        if (choice == null || !context.mounted) return;
        if (choice == 'sweep') store.closeSettled(store.loose);
      },
    );
  }
}

/// A named job inside a folder, with its panels under it.
///
/// It looks like the worktree folder one level down and behaves like the
/// folder one level up, which is the point: the sidebar is now three deep —
/// where the code is, what it is for, and who is working on it.
class _ProjectGroup extends StatelessWidget {
  const _ProjectGroup({
    super.key,
    required this.store,
    required this.folder,
    required this.project,
  });

  final AppStore store;
  final Folder folder;
  final Project project;

  @override
  Widget build(BuildContext context) {
    final tabs = store.visible(store.tabsIn(project));
    final alerts = store.needingHumanIn(project);
    // Ver [_FolderGroup]: durante a busca, o que está dobrado abre.
    final collapsed = project.collapsed && !store.filtering;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Dropping a panel on the header is how it joins: the same drag that
        // reorders panels, aimed one row higher.
        _ProjectDrop(
          store: store,
          project: project,
          child: _Hoverable(
            builder: (hovered) => InkWell(
              onTap: () => store.toggleProjectCollapsed(project),
              onSecondaryTapDown: (d) =>
                  showProjectMenu(context, store, folder, project, d.globalPosition),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(7, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 16,
                      color: Mx.fgDim,
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.workspaces_outline, size: 15, color: Mx.purple),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        project.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    // The briefing is invisible by nature — it is in a system
                    // prompt you never see scroll by. This is the only place
                    // that says a project has one.
                    if (project.brief.trim().isNotEmpty)
                      Tooltip(
                        message: project.brief.trim(),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 5),
                          child: Icon(Icons.sticky_note_2_outlined, size: 13, color: Mx.fgFaint),
                        ),
                      ),
                    if (alerts > 0) _Badge(count: alerts),
                    Text('${tabs.length}', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                    _AddButton(
                      store: store,
                      folder: folder,
                      project: project,
                      shown: hovered || tabs.isEmpty,
                    ),
                    _RowButton(
                      tooltip: 'o que fazer com esse projeto',
                      icon: Icons.more_horiz,
                      onTap: (anchor) => showProjectMenu(context, store, folder, project, anchor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Empty and open, a project used to still draw a rail -- it had the
        // chip strip hanging off it. With the strip gone there is nothing to
        // hang, and a stub of line under a header says less than no line.
        if (!collapsed && tabs.isNotEmpty)
          _Nest(
            rail: 15,
            children: [
              for (final t in tabs) _TabRow(key: ValueKey(t.id), store: store, tab: t),
              const SizedBox(height: 4),
            ],
          ),
      ],
    );
  }
}

/// The project header as somewhere to drop a panel.
///
/// Only panels of the same folder light it up — a project's briefing talks
/// about a checkout, so a session running somewhere else could not be told to
/// obey it.
class _ProjectDrop extends StatefulWidget {
  const _ProjectDrop({required this.store, required this.project, required this.child});

  final AppStore store;
  final Project project;
  final Widget child;

  @override
  State<_ProjectDrop> createState() => _ProjectDropState();
}

class _ProjectDropState extends State<_ProjectDrop> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<MxTab>(
      onWillAcceptWithDetails: (d) {
        if (d.data.folderRoot != widget.project.folderRoot) return false;
        if (d.data.projectId == widget.project.id) return false;
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) {
        if (_over) setState(() => _over = false);
      },
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.store.assign(d.data, widget.project);
      },
      builder: (context, _, _) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: _over ? Mx.bgHover : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.fromBorderSide(_over ? BorderSide(color: Mx.accent) : BorderSide.none),
        ),
        child: widget.child,
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({super.key, required this.store, required this.tab});
  final AppStore store;
  final MxTab tab;

  @override
  Widget build(BuildContext context) {
    final selected = store.isOpen(tab);
    // Which pane has the keyboard, so four selected rows are still readable.
    final focused = selected && store.focusedPaneId == tab.id;
    final index = store.tabs.indexWhere((t) => t.id == tab.id);
    final row = _Row(
      selected: selected,
      focused: focused,
      // Concluída, a linha recua um passo: título apagado, marca apagada. Ela
      // continua ali — é uma sessão que você guardou de propósito — mas para
      // de disputar o olho com as que ainda estão trabalhando.
      dim: tab.done,
      leading: tab.kind == TabKind.claude
          ? ClaudeAvatar(status: tab.status, size: 26, dim: tab.done)
          : Icon(Icons.chevron_right, size: 19, color: Mx.fgDim),
      title: tab.title,
      subtitle: tab.subtitle,
      trailing: Row(
        children: [
          // O tique de "essa funcionou", dito por fora do badge de estado de
          // propósito: o badge diz o que a sessão está fazendo, e isso é uma
          // coisa que só você sabe sobre ela.
          if (tab.done)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Tooltip(
                message: 'concluída',
                child: Icon(Icons.task_alt, size: 14, color: Mx.green),
              ),
            ),
          if (tab.followUps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: FollowUpMark(tab: tab),
            ),
          if (tab.dirty > 0)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Icon(Icons.circle, size: 6, color: Mx.yellow),
            ),
          if (!tab.done && tab.status.needsHuman) _Badge(count: 1, color: tab.status.color),
          if (index >= 0 && index < 9)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '⌘${index + 1}',
                style: TextStyle(fontFamily: Mx.mono, fontSize: 10.5, color: Mx.fgFaint),
              ),
            ),
          // Claude rows say their state on the badge stamped into the mark;
          // a shell has no badge, so it keeps the dot.
          if (tab.kind == TabKind.shell) StatusDot(status: tab.status, size: 9),
        ],
      ),
      onTap: () => store.select(tab),
      onClose: () => store.closeTab(tab),
      onSecondary: (pos) => showPanelMenu(context, store, tab, pos),
    );
    final dragging = _PanelDrag(store: store, tab: tab, child: row);

    // Forks hang off the panel that spawned them, the way panels hang off a
    // project: the same rail, one level in. They sit outside the drag wrapper
    // because they are not a thing you can pick up -- a subagent belongs to
    // its session and goes where the session goes.
    final fleet = tab.hooks.subagents.values.toList();
    if (fleet.isEmpty) return dragging;
    final collapsed = tab.fleetCollapsed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        dragging,
        _Nest(
          rail: 35,
          children: [
            _FleetHeader(store: store, tab: tab, fleet: fleet),
            if (!collapsed)
              for (final agent in fleet)
                _SubagentRow(key: ValueKey(agent.agentId), tab: tab, agent: agent),
          ],
        ),
        const SizedBox(height: 3),
      ],
    );
  }
}

/// The fold, with the count that makes folding it safe: collapsed, this line
/// is the only thing left saying the forks are there.
class _FleetHeader extends StatelessWidget {
  const _FleetHeader({required this.store, required this.tab, required this.fleet});

  final AppStore store;
  final MxTab tab;
  final List<SubagentState> fleet;

  @override
  Widget build(BuildContext context) {
    final live = fleet.where((a) => a.running).length;
    final collapsed = tab.fleetCollapsed;
    final label = live > 0
        ? '${fleet.length} ${fleet.length == 1 ? 'agente' : 'agentes'} · $live rodando'
        : '${fleet.length} ${fleet.length == 1 ? 'agente' : 'agentes'}';

    return InkWell(
      onTap: () => store.toggleFleet(tab),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 5, 9, 5),
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 14, color: Mx.fgDim),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
          ],
        ),
      ),
    );
  }
}

/// One fork under its panel: what it was sent to do, and how it is going.
///
/// Deliberately not a [_Row]. A subagent is not somewhere you can go -- there
/// is no pane to open, nothing to close, no shortcut to press -- so it gets a
/// line, not a target.
class _SubagentRow extends StatelessWidget {
  const _SubagentRow({super.key, required this.tab, required this.agent});

  final MxTab tab;
  final SubagentState agent;

  @override
  Widget build(BuildContext context) {
    final done = !agent.running;
    return InkWell(
      onTap: () => showSubagent(context, tab, agent),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 9, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                done ? Icons.check : Icons.call_split,
                size: 12,
                color: done ? Mx.fgFaint : agent.shownStatus.color,
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    agent.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: done ? Mx.fgDim : Mx.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    agent.subtitle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: Mx.fgFaint),
                  ),
                ],
              ),
            ),
            // Only worth saying when it changes what the panel's own status
            // means: the session went back to the prompt, this did not stop.
            if (agent.background && !done)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 1),
                child: Text(
                  'bg',
                  style: TextStyle(fontFamily: Mx.mono, fontSize: 9.5, color: Mx.fgFaint),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A panel row you can pick up and drop onto another to reorder the list.
///
/// The panel lands on the slot of the row you dropped it on, the way a
/// reorderable list does it. Nothing else moves, so ⌘1..9 — the same list
/// counted from the top — and the order the layout is saved in both follow
/// what you dragged.
///
/// Panels stay inside their own folder: one is a session running in a folder
/// of that repo, so the same row under another folder would be a lie about
/// where it is. A panel dragged from another group simply never lights a row
/// up.
class _PanelDrag extends StatefulWidget {
  const _PanelDrag({required this.store, required this.tab, required this.child});

  final AppStore store;
  final MxTab tab;
  final Widget child;

  @override
  State<_PanelDrag> createState() => _PanelDragState();
}

class _PanelDragState extends State<_PanelDrag> {
  /// The panel hovering over this row, once it is one this row would take.
  MxTab? _incoming;

  /// Onde dentro da linha o mouse a pegou. Ver [DragCursor].
  Offset _grab = Offset.zero;

  /// Which edge the line goes on. A panel dropped from above takes this row's
  /// slot and pushes it up, so it ends up below; one from below ends up above.
  bool get _fromAbove {
    final list = widget.store.tabs;
    return list.indexOf(_incoming!) < list.indexOf(widget.tab);
  }

  @override
  Widget build(BuildContext context) {
    // The width the row is laid out at, so the one in the air is the same row
    // and not whatever the overlay would give an unconstrained one.
    return LayoutBuilder(
      builder: (context, box) => DragTarget<MxTab>(
        onWillAcceptWithDetails: (d) {
          // Dropped back on the row it was picked up from. A mouse drag starts
          // after a single pixel, so that is a click whose pointer drifted —
          // and it is honoured as the click it was meant to be.
          if (identical(d.data, widget.tab)) return true;
          if (d.data.folderRoot != widget.tab.folderRoot) return false;
          setState(() => _incoming = d.data);
          return true;
        },
        onLeave: (_) {
          if (_incoming != null) setState(() => _incoming = null);
        },
        onAcceptWithDetails: (d) {
          setState(() => _incoming = null);
          if (identical(d.data, widget.tab)) {
            widget.store.select(widget.tab);
          } else {
            widget.store.moveTab(d.data, widget.tab);
          }
        },
        builder: (context, _, _) => Stack(
          children: [
            Draggable<MxTab>(
              data: widget.tab,
              feedback: _lifted(box.maxWidth),
              // Por onde a linha foi pega, dito a quem vai receber o drop: é o
              // que falta pro painel embaixo do mouse saber onde o mouse está.
              // Ver [DragCursor]. O mesmo ponto que o Flutter usa pra ancorar o
              // cartão que voa, medido de onde ele mede.
              onDragStarted: () => DragCursor.grab = _grab,
              // The hole it leaves behind: still a row, so the list keeps its
              // shape while one of them is in the air.
              childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
              child: Listener(onPointerDown: (e) => _grab = e.localPosition, child: widget.child),
            ),
            if (_incoming != null)
              Positioned(
                // Inset to the row's own margin, so the line is as wide as the
                // tiles it is pointing between.
                left: 7,
                right: 7,
                top: _fromAbove ? null : 0,
                bottom: _fromAbove ? 0 : null,
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

  /// The row in the air: a piece of the sidebar, lifted off it.
  ///
  /// It brings its own background because the overlay it flies in has none —
  /// a row whose fill is transparent until you hover it would otherwise drag
  /// across the terminal as loose text.
  Widget _lifted(double width) => Material(
    type: MaterialType.transparency,
    child: SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Mx.bgSidebar,
          borderRadius: BorderRadius.circular(12),
          border: Border.fromBorderSide(BorderSide(color: Mx.accent.withValues(alpha: 0.55))),
          boxShadow: [BoxShadow(color: Mx.shadow, blurRadius: 18, offset: const Offset(0, 8))],
        ),
        child: widget.child,
      ),
    ),
  );
}

/// A folder's glyph: a folder, plus — when the folder turned out to be a git
/// repo — the branch mark welded onto its corner. Together they say "repo
/// folder" without spending a word on it; a plain folder stays a plain folder.
class RepoGlyph extends StatelessWidget {
  const RepoGlyph({super.key, required this.isRepo, this.size = 17});
  final bool isRepo;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!isRepo) {
      return Icon(Icons.folder_outlined, size: size, color: Mx.fgFaint);
    }
    return SizedBox(
      width: size + 3,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.folder_rounded, size: size, color: Mx.fgDim),
          Positioned(
            right: 0,
            bottom: -1,
            // A ring in the sidebar's own colour, so the mark reads as a badge
            // on the folder instead of a scratch across it.
            child: Container(
              decoration: BoxDecoration(color: Mx.bgSidebar, shape: BoxShape.circle),
              padding: const EdgeInsets.all(1),
              child: Icon(Icons.call_split, size: size * 0.55, color: Mx.purple),
            ),
          ),
        ],
      ),
    );
  }
}

/// The repo's worktrees, in a folder of their own that folds shut.
///
/// Loose in the tree they outnumbered the sessions and there was no way to
/// dismiss them — five branches nobody is touching right now are reference
/// material, not the point of the sidebar. Folded is the default, and
/// [Folder.worktreesCollapsed] remembers what you chose.
///
/// It sits at the top of the folder, above the sessions: it is the one row in
/// there whose place never changes, and a landmark that drifts down the list
/// as panels come and go is not a landmark.
///
/// Folded, this one line is the whole feature, so it has to earn the click it
/// asks for. It used to ask with a generic folder glyph — the same mark the
/// repo above already carries, saying "directory" where the truth is
/// "branches" — a bare digit floating beside the word, and no answer at all to
/// the pointer. Now the branch mark says what is inside, the count rides in a
/// chip, and the strip lights up under the pointer the way the rows below it
/// do.
class _WorktreeFolder extends StatefulWidget {
  const _WorktreeFolder({required this.store, required this.folder, required this.worktrees});
  final AppStore store;
  final Folder folder;
  final List<WorktreeInfo> worktrees;

  @override
  State<_WorktreeFolder> createState() => _WorktreeFolderState();
}

class _WorktreeFolderState extends State<_WorktreeFolder> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final worktrees = widget.worktrees;
    if (worktrees.isEmpty) return const SizedBox.shrink();
    final collapsed = widget.folder.worktreesCollapsed;
    final ghosts = worktrees.where((w) => w.prunable).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: InkWell(
            onTap: () => widget.store.toggleWorktrees(widget.folder),
            borderRadius: BorderRadius.circular(8),
            // The fill below already answers the pointer; a wash on top of it
            // would only mud the colour.
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            // Not animated, and neither is anything on the line: the tiles
            // right below it snap between their fills, and a header that faded
            // where they snap was the odd one out.
            child: Container(
              // Inset a step less than the tiles below so the fill still
              // clears their rail. The chevron lands on x=7 and is 16 wide,
              // which is what puts that rail at 15.
              margin: const EdgeInsets.fromLTRB(4, 3, 7, 3),
              padding: const EdgeInsets.fromLTRB(3, 6, 8, 6),
              decoration: BoxDecoration(
                color: _hover ? Mx.bgHover : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  // One chevron that turns, rather than two that swap: folding
                  // is a state of this line, not a different line.
                  AnimatedRotation(
                    turns: collapsed ? 0 : 0.25,
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: _hover ? Mx.fgDim : Mx.fgFaint,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // The same mark every worktree row wears, one level up: what
                  // is folded away in here is branches, not files.
                  Icon(Icons.call_split, size: 13, color: _hover ? Mx.fgDim : Mx.fgFaint),
                  const SizedBox(width: 7),
                  Text(
                    'worktrees',
                    style: TextStyle(
                      fontSize: 11.5,
                      letterSpacing: 0.2,
                      color: _hover ? Mx.fg : Mx.fgDim,
                    ),
                  ),
                  const SizedBox(width: 7),
                  _CountChip(count: worktrees.length),
                  const Spacer(),
                  // Registrations git itself calls prunable. Worth its own
                  // chip on the folded line: it is the one thing in here that
                  // wants doing.
                  if (ghosts > 0) _GhostChip(count: ghosts),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed) ...[
          _Nest(
            rail: 15,
            children: [
              for (final w in worktrees)
                _WorktreeRow(store: widget.store, folder: widget.folder, worktree: w),
            ],
          ),
          // Where the rail ends and the sessions start. Opened, the last
          // worktree used to sit as close to the first panel as it did to the
          // worktree above it, and the two lists read as one.
          const SizedBox(height: 5),
        ],
      ],
    );
  }
}

/// How many worktrees are folded away, in a chip. Loose beside the label the
/// digit read as a stray character of it; boxed, it reads as a quantity.
///
/// One fill, and it is the surface *above* the one hover puts under it: a chip
/// that answered the pointer too crossed the line's own fill on the way, and
/// for a frame in the middle the two colours were the same and the chip
/// blinked out.
class _CountChip extends StatelessWidget {
  const _CountChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(color: Mx.bgActive, borderRadius: BorderRadius.circular(6)),
      child: Text('$count', style: TextStyle(fontSize: 10, height: 1.2, color: Mx.fgDim)),
    );
  }
}

/// The worktrees git would prune: a folder that is gone and a registration
/// that is not. Yellow on a tint of itself rather than a loose icon and a
/// loose number, so it reads as one mark — a warning with a count on it.
class _GhostChip extends StatelessWidget {
  const _GhostChip({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: count == 1 ? 'uma sem pasta no disco' : '$count sem pasta no disco',
      child: Container(
        padding: const EdgeInsets.fromLTRB(5, 2, 6, 2),
        decoration: BoxDecoration(
          color: Mx.yellow.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off, size: 11, color: Mx.yellow),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Mx.yellow),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorktreeRow extends StatelessWidget {
  const _WorktreeRow({required this.store, required this.folder, required this.worktree});
  final AppStore store;
  final Folder folder;
  final WorktreeInfo worktree;

  @override
  Widget build(BuildContext context) {
    final ghost = worktree.prunable;
    final open = store.tabAt(worktree.path);

    return _Row(
      selected: false,
      dim: true,
      leading: Icon(
        ghost
            ? Icons.link_off
            : worktree.isMain
            ? Icons.home_outlined
            : Icons.call_split,
        size: 18,
        color: ghost ? Mx.yellow : Mx.fgFaint,
      ),
      title: worktree.isMain ? folder.name : worktree.shortLabel,
      subtitle: ghost
          ? 'a pasta não existe mais — só o registro no git'
          : open != null
          ? '${worktree.branch} · sessão aberta'
          : worktree.branch,
      trailing: Row(
        children: [
          if (!ghost)
            _RowButton(
              tooltip: open == null ? 'nova sessão do claude aqui' : 'ir pro painel',
              icon: open == null ? Icons.play_arrow_rounded : Icons.arrow_forward_rounded,
              onTap: (_) {
                if (open != null) {
                  store.select(open);
                } else {
                  store.openClaude(
                    folder,
                    cwd: worktree.path,
                    label: worktree.isMain ? null : worktree.shortLabel,
                  );
                }
              },
            ),
          _RowButton(
            tooltip: 'o que fazer com essa worktree',
            icon: Icons.more_horiz,
            onTap: (anchor) => showWorktreeMenu(context, store, folder, worktree, anchor),
          ),
        ],
      ),
      // A worktree is a folder before it is anything else, so the row itself
      // hands it to the editor. Starting a session in it is the ▶, and deleting
      // it lives behind the ⋯ — which is where a destructive thing belongs.
      onTap: ghost ? null : () => store.openInEditor(worktree.path),
      onSecondary: (pos) => showWorktreeMenu(context, store, folder, worktree, pos),
    );
  }
}

/// A small control inside a row: the row is the primary target, this is one of
/// the other two things you can do to it. It reports where it is, so a menu
/// opens under the glyph you actually clicked.
class _RowButton extends StatelessWidget {
  const _RowButton({required this.tooltip, required this.icon, required this.onTap});
  final String tooltip;
  final IconData icon;
  final void Function(Offset anchor) onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Builder(
        builder: (ctx) => InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: () {
            final box = ctx.findRenderObject() as RenderBox?;
            onTap(box == null ? Offset.zero : box.localToGlobal(box.size.bottomLeft(Offset.zero)));
          },
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(icon, size: 18, color: Mx.fgFaint),
          ),
        ),
      ),
    );
  }
}

/// A header row that knows whether the pointer is on it, so the controls that
/// only matter while you are aiming at the row can stay out of the way the
/// rest of the time.
class _Hoverable extends StatefulWidget {
  const _Hoverable({required this.builder});
  final Widget Function(bool hovered) builder;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(_hovered),
  );
}

/// The + on a header row: everything you can start here, behind one target.
///
/// It replaced a strip of "+ terminal / + sessão / + projeto" chips repeated
/// under every folder and every project — nine buttons on a sidebar holding
/// three folders, all offering the same three things and all pushing the rows
/// they belong to further down. Now the offer lives where the thing being
/// added would go, and only while you are pointing at it.
///
/// Hidden or shown, the space is reserved: a control that appears under the
/// pointer must not shove the rest of the row sideways when it does.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.store, required this.folder, this.project, required this.shown});

  final AppStore store;
  final Folder folder;

  /// Set on a project's header: what the menu starts joins that project and
  /// comes up with its briefing.
  final Project? project;

  /// Whether the pointer is on the row this rides on — or the group has
  /// nothing in it, in which case there are no rows to hover over and the +
  /// is the only thing left to aim at.
  final bool shown;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: shown ? 1 : 0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      // Invisible is also unclickable: a + you cannot see that still answers
      // the pointer is a trap on a row whose own job is to fold and unfold.
      child: IgnorePointer(
        ignoring: !shown,
        child: _RowButton(
          // Three different rows can hold one of these, and the tooltip is the
          // only thing that says which of them you are about to add to.
          tooltip: project != null
              ? 'abrir algo nesse projeto'
              : folder.isLoose
              ? 'abrir algo sem pasta'
              : 'abrir algo nessa pasta',
          icon: Icons.add,
          onTap: (anchor) => _showAddMenu(context, store, folder, project, anchor),
        ),
      ),
    );
  }
}

/// What the + offers, written down once. The same three things the chip strip
/// used to spell out, minus the ones that would mean nothing where the menu
/// opened: a project cannot hold a project, and neither can the loose tray.
Future<void> _showAddMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  Project? project,
  Offset anchor,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final choice = await showMenu<String>(
    context: context,
    color: Mx.bgActive,
    position: RelativeRect.fromRect(anchor & Size.zero, Offset.zero & overlay.size),
    items: [
      // The session first: it is what you are almost always here for, and the
      // chip strip's left-to-right order was never that.
      _addItem('claude', const ClaudeMark(size: 13), 'sessão do claude'),
      _addItem('shell', Icon(Icons.terminal, size: 14, color: Mx.fgDim), 'terminal'),
      if (project == null && !folder.isLoose)
        _addItem('projeto', Icon(Icons.workspaces_outline, size: 14, color: Mx.purple), 'projeto…'),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'claude':
      store.openClaude(folder, cwd: folder.root, project: project);
    case 'shell':
      store.openShell(folder, project: project);
    case 'projeto':
      await showNewProject(context, store, folder);
  }
}

/// A line of the + menu: the glyph the chip used to carry, kept because it is
/// what made the three offers tellable apart at a glance.
PopupMenuItem<String> _addItem(String value, Widget glyph, String label) => PopupMenuItem(
  value: value,
  height: 34,
  child: Row(
    children: [
      SizedBox(width: 16, child: Center(child: glyph)),
      const SizedBox(width: 9),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  ),
);

class _FolderMenu extends StatelessWidget {
  const _FolderMenu({required this.store, required this.folder});
  final AppStore store;
  final Folder folder;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      iconSize: 16,
      padding: EdgeInsets.zero,
      color: Mx.bgActive,
      icon: Icon(Icons.more_horiz, color: Mx.fgFaint),
      onSelected: (v) async {
        switch (v) {
          case 'rename':
            final name = await promptText(
              context,
              title: 'renomear pasta',
              initial: folder.name,
              label: 'nome',
            );
            if (name != null && name.trim().isNotEmpty) {
              store.renameFolder(folder, name.trim());
            }
          case 'task':
            await showNewTask(context, store, folder);
          case 'newproject':
            await showNewProject(context, store, folder);
          case 'refresh':
            await store.refreshGit();
          case 'prune':
            await store.pruneWorktrees(folder);
          case 'sweep':
            store.closeSettled(folder);
          case 'remove':
            await store.removeFolder(folder);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'task',
          height: 34,
          child: Text('nova task…', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'newproject',
          height: 34,
          child: Text('novo projeto…', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'rename',
          height: 34,
          child: Text('renomear', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'refresh',
          height: 34,
          child: Text('atualizar git', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'prune',
          height: 34,
          child: Text('limpar worktrees fantasmas', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'sweep',
          height: 34,
          child: Text('limpar encerrados e concluídos', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem(
          value: 'remove',
          height: 34,
          child: Text('remover pasta', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// Everything that lives under a folder row: stepped in, and hung off a rail
/// that drops from the folder's own chevron.
///
/// The step is what says "inside" at a glance — before this the tiles started
/// further left than the chevron above them, so a folder read as a label
/// sitting on top of a flat list rather than as something the list is in. The
/// line is what keeps saying it once a folder has enough tiles that its
/// header has scrolled out of sight.
class _Nest extends StatelessWidget {
  const _Nest({required this.children, this.rail = 20});

  final List<Widget> children;

  /// Where the rail falls, measured from the parent row's left edge. A folder
  /// header's chevron sits at x=10 and is 20 wide, so 20 lands on its centre.
  final double rail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(left: rail),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: Mx.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.selected,
    this.focused = false,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
    this.onSecondary,
    this.onClose,
    this.dim = false,
  });

  final bool selected;
  final bool focused;
  final bool dim;
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;

  /// Null for a row with nothing to open — a worktree whose folder is gone.
  final VoidCallback? onTap;

  /// Present only on rows that own their pty. Its button rides in the
  /// trailing slot, and only while the pointer is on the row.
  final VoidCallback? onClose;

  /// Takes the pointer position, so a context menu can open where you clicked.
  final void Function(Offset globalPosition)? onSecondary;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // No stripe: which pane holds the keyboard is said by how lit the row is.
    // Selected-and-focused sits on the active surface, its twin in the other
    // pane a step darker — the same two steps hover already uses.
    final background = widget.selected
        ? (widget.focused ? Mx.bgActive : Mx.bgHover)
        : (_hovered ? Mx.bgHover : Colors.transparent);
    final showClose = widget.onClose != null && _hovered;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapDown: widget.onSecondary == null
            ? null
            : (d) => widget.onSecondary!(d.globalPosition),
        child: InkWell(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.only(left: 7, right: 7, top: 3, bottom: 3),
            padding: const EdgeInsets.fromLTRB(11, 11, 9, 11),
            decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(9)),
            child: Row(
              children: [
                SizedBox(width: 34, child: Center(child: widget.leading)),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          color: widget.dim ? Mx.fgDim : Mx.fg,
                          fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      if (widget.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          widget.subtitle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(fontSize: 12, color: Mx.fgFaint),
                        ),
                      ],
                    ],
                  ),
                ),
                // The x takes the meta's place rather than sitting beside it:
                // the row is narrow, and the shortcut hint is the thing you
                // stop needing the moment you have reached for the mouse.
                showClose ? _CloseButton(onTap: widget.onClose!) : widget.trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The x on a hovered row. Its own hover state, so the target lights up before
/// you commit to a click that ends a session.
class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'fechar painel',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hovered ? Mx.border : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.close_rounded, size: 15, color: _hovered ? Mx.fg : Mx.fgDim),
          ),
        ),
      ),
    );
  }
}

/// The count of things waiting on you in a row.
///
/// Takes the state's colour rather than being red always: red on a session
/// that had only asked a question read as an alarm, next to a lock badge
/// saying the same wrong thing. The pill is the *count*; which kind of
/// waiting it is belongs to the colour it inherits.
class _Badge extends StatelessWidget {
  const _Badge({required this.count, this.color});
  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? Mx.red;
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 5.5, vertical: 1.5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          // Yellow is a light pill: white numerals on it are unreadable, and
          // the palette's own canvas is what every other chip punches out to.
          color: bg.computeLuminance() > 0.5 ? Mx.canvas : Colors.white,
        ),
      ),
    );
  }
}

/// A busca não achou nada. Diz o que foi procurado — o campo pode estar
/// rolado pra fora do olho, e um filtro marcado não está escrito em lugar
/// nenhum — e oferece a saída no mesmo lugar onde a pergunta morreu.
class _NoHits extends StatelessWidget {
  const _NoHits({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final filters = store.activeFilters;
    final what = [
      if (store.query.trim().isNotEmpty) '“${store.query.trim()}”',
      if (filters > 0) '$filters ${filters == 1 ? 'filtro' : 'filtros'}',
    ].join(' + ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'nenhuma sessão com $what.',
            style: TextStyle(color: Mx.fgDim, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 14),
          _HeaderAction(
            icon: Icons.filter_list_off_rounded,
            label: 'mostrar tudo',
            tooltip: 'limpar a busca e os filtros',
            onPressed: store.clearSearch,
          ),
        ],
      ),
    );
  }
}

class _NoFolders extends StatelessWidget {
  // Not const — see EmptyPane: it reads the palette at build time.
  // ignore: prefer_const_constructors_in_immutables
  _NoFolders();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Text(
        'nenhuma pasta ainda.\n\nsessões do claude já rodando aparecem aqui sozinhas — '
        'ou use o + lá em cima pra adicionar um repo.\n\npra abrir um painel sem pasta '
        'nenhuma, o + na linha de "avulsos" logo abaixo.',
        style: TextStyle(color: Mx.fgFaint, fontSize: 12.5, height: 1.55),
      ),
    );
  }
}
