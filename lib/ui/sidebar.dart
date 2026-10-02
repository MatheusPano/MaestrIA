import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/plugins.dart';
import '../services/shortcuts.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';
import 'dialogs.dart';
import 'icons.dart';
import 'menus.dart';
import 'panel.dart';
import 'panes.dart';
import 'plugin_pane.dart';
import 'settings.dart';
import 'terminal_pane.dart';

part 'sidebar_workspaces.dart';

/// Folders, each with its panels underneath. The shape of the whole app.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    // The width is the parent's to decide: the gutter beside it is a drag
    // handle, and AppStore.sidebarWidth is what it drags.
    //
    // Uma aba de plugin troca o miolo inteiro, cabeçalho incluído: a busca
    // procura sessão, e ali não há sessão pra procurar. O rodapé fica -- ele é
    // da janela, e não do que a lateral está mostrando. Ver [SidebarRail].
    if (store.shownPlugin case final plugin?) {
      return MxPanel(
        color: Mx.bgSidebar,
        child: Column(
          children: [
            _PluginHeader(store: store, plugin: plugin),
            Expanded(
              child: _PluginPage(key: ValueKey('page:${plugin.id}'), store: store, plugin: plugin),
            ),
            _Footer(store: store),
          ],
        ),
      );
    }
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
                // Os arranjos salvos abrem a lista. Uma busca em curso os
                // esconde: procura-se sessão, e um grupo não é uma.
                if (store.groups.isNotEmpty && !store.filtering)
                  _GroupTray(key: const ValueKey('groups'), store: store),
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
                //
                // Uma linha é uma pasta ou uma seção de workspace -- ver
                // `AppStore.sidebarRows`. As duas condições são exclusivas por
                // construção, então cada `row` desenha uma coisa só.
                for (final row in store.sidebarRows) ...[
                  if (row case final Workspace w)
                    if (!store.filtering || store.hasHitsInWorkspace(w))
                      _WorkspaceSection(key: ValueKey(w.id), store: store, workspace: w),
                  if (row case final Folder p)
                    if (!store.filtering || store.hasHits(p))
                      _FolderGroup(key: ValueKey(p.root), store: store, folder: p),
                ],
                if (!store.filtering || store.hasHits(store.loose))
                  _LooseTray(key: const ValueKey('loose'), store: store),
                // As janelas de plugin não moram aqui: cada plugin tem a aba
                // dele na faixa ao lado. Empilhadas embaixo dos avulsos, duas
                // ferramentas já eram duas seções inteiras disputando altura
                // com o trabalho. Ver [SidebarRail].
              ],
            ),
          ),
          _Footer(store: store),
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
    // A busca e a engrenagem, e mais nada. Os outros dois glifos desceram pro
    // rodapé (ver [_Footer]) porque saíam do mesmo orçamento de largura que o
    // campo — três botões deixavam o campo com 62px de texto no `minSidebar`,
    // e o quarto não teria onde caber.
    //
    // A engrenagem ficou: adicionar pasta, retomar conversa e pedir relatório
    // produzem coisa que aparece na lista logo abaixo, e a mão vai buscá-los
    // perto do que eles fazem. Configuração não produz nada aqui dentro — é o canto da janela, e
    // o canto da janela é aqui em cima. Uma sozinha custa 40px do campo; três
    // custavam 112, que é a conta que motivou tudo isto.
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Mx.border)),
      ),
      child: Row(
        spacing: _StripIcon.gap,
        children: [
          Expanded(child: _SearchField(store: store)),
          _StripIcon(
            icon: Icons.settings_outlined,
            // A tecla vem do mapa e não de um literal: ela é editável agora, e
            // um tooltip que ensinasse ⌘⇧P a quem trocou por outra estaria
            // simplesmente errado.
            tooltip: [
              'configurações',
              ...store.keymap[MxAction.settings].map((c) => c.label),
            ].join('  '),
            onPressed: () => showSettings(context, store),
          ),
        ],
      ),
    );
  }
}

/// A fileira de glifos no pé da lateral: adicionar uma pasta, retomar uma
/// conversa e pedir o relatório do dia — as coisas que produzem alguma coisa
/// na lista logo acima. A engrenagem não é uma delas e ficou no cabeçalho.
///
/// A ordem é a do dia: primeiro o lugar onde se vai trabalhar, depois a sessão
/// que já trabalhou nele, e por último o que foi feito.
///
/// O medidor de plano fica no canto oposto, com um vão entre ele e os três.
/// Ele também não produz nada na lista -- é a mesma razão que mandou a
/// engrenagem pro cabeçalho --, mas é uma pergunta que se faz *antes* de abrir
/// a próxima sessão, e o cabeçalho não tem largura pra um segundo glifo. O vão
/// é o que o impede de ler como o quarto de uma fileira de quatro.
///
/// Moraram no header até ficar claro que saíam do mesmo orçamento de largura
/// que a busca — e que o problema não era o terceiro glifo, era o quarto. Numa
/// faixa horizontal deste tamanho cabem sete botões de 30 mesmo com a lateral
/// no mínimo; o header aguentava três, e só na largura padrão.
///
/// À esquerda, e não à direita, porque é onde o VS Code, o Slack e o Linear
/// puseram a mesma fileira: é o canto que o olho varre quando procura o que a
/// janela faz, e não o que ela está mostrando.
class _Footer extends StatelessWidget {
  const _Footer({required this.store});
  final AppStore store;

  // A fileira é do Material, e o traço dele é mais pesado que o do VS Code:
  // 2px sobre 24 contra ~1px sobre 16 dos codicons. Não é ajuste, é a fonte --
  // `MaterialIcons-Regular.otf` não tem eixo de peso, então `Icon.weight` não
  // faz nada aqui. Afinar de verdade custa um pacote: `material_symbols_icons`
  // traz a fonte variável e aí `weight: 200` passa a valer.
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      // O padding que põe o primeiro contorno na mesma coluna da lupa do campo,
      // 16px da borda: o alvo tem 36 e o glifo 18, então sobram 9 de folga
      // dentro do botão e 7 é o que falta pra fechar a conta.
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Mx.border)),
      ),
      child: Row(
        spacing: _StripIcon.gap,
        children: [
          _StripIcon(
            // Sem rótulo: `create_new_folder` já é a pasta *e* o +, então a
            // palavra ao lado era repetição. O tooltip continua dizendo o que
            // ele adiciona.
            icon: Icons.create_new_folder_outlined,
            tooltip: 'adicionar uma pasta ao cockpit',
            onPressed: () => showAddFolder(context, store),
          ),
          // O histórico, inteiro: todas as pastas de uma vez, repartido por
          // pasta -- e este é o único lugar por onde se chega nele. A lista
          // esteve também no menu de cada pasta, filtrada nela, e era escolher
          // antes de ver: a conversa de um repo que não está na lateral não
          // aparecia em nenhuma das seis listas de pasta, só nesta. Ver
          // [showChatHistory].
          _StripIcon(
            // O relógio que era a linha "retomar conversa…" dos menus, na
            // versão vazada que esta faixa pede de todos os glifos: quem
            // procurava a linha reconhece o desenho dela aqui. Ver
            // [_StripIcon].
            icon: Icons.history_outlined,
            tooltip: 'retomar uma conversa',
            onPressed: () => showChatHistory(context, store),
          ),
          // Os comandos de plugin que pediram um lugar aqui -- o relatório do
          // dia morava nesta posição antes de virar plugin, e é o caso que o
          // lugar existe pra servir: coisa da janela, não de um painel. Ver
          // [Plugins.sidebarCommands].
          //
          // Os de um plugin que tem aba na faixa ficam fora: o ícone dele já
          // está lá. Ver [AppStore.footerCommands].
          for (final command in store.footerCommands) _PluginIcon(store: store, command: command),
          const Spacer(),
          // O mesmo desenho da seção que ele abre (ver [MxSection.account]):
          // são o mesmo lugar visto de dois cantos da janela, e um segundo
          // desenho pra ele faria pensar que não são.
          _StripIcon(
            icon: MxSection.account.icon,
            tooltip: MxSection.account.label,
            onPressed: () => showSettings(context, store, section: MxSection.account),
          ),
          // O interruptor da própria lateral, no canto mais longe dos três que
          // produzem linha na lista: ele não produz nada aqui dentro -- tira
          // isto aqui da tela. A volta é a faixa ao lado, que fica na tela
          // (ver [SidebarRail]).
          //
          // Cabe aqui e não no cabeçalho pela conta que mandou os outros dois
          // pra cá: um segundo glifo lá em cima custa 40px do campo de busca, e
          // esta faixa tem largura sobrando mesmo no `minSidebar`.
          _StripIcon(
            icon: Icons.view_sidebar_outlined,
            tooltip: [
              'esconder a lateral',
              ...store.keymap[MxAction.toggleSidebar].map((c) => c.label),
            ].join('  '),
            onPressed: store.toggleSidebar,
          ),
        ],
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
              shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): _ClearIntent()},
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
          ? 'filtrar por pasta, feature/hotfix ou estado'
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
  final String label;
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
                const SizedBox(width: 5),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _hover ? Mx.fg : Mx.fgDim,
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

/// O botão de um comando de plugin no rodapé.
///
/// Vira um spinner enquanto o plugin diz que o comando está rodando
/// (`command.busy`): o relatório do dia leva dezenas de segundos, e um botão
/// que não diz isso é um botão que parece não ter funcionado -- e que se
/// clica de novo.
class _PluginIcon extends StatelessWidget {
  const _PluginIcon({required this.store, required this.command});
  final AppStore store;
  final PluginCommand command;

  @override
  Widget build(BuildContext context) {
    if (store.plugins.busy.contains(command.fullId)) {
      return const SizedBox(
        width: _StripIcon.box,
        height: _StripIcon.box,
        child: Center(
          child: SizedBox(
            width: _StripIcon.glyph - 5,
            height: _StripIcon.glyph - 5,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        ),
      );
    }
    return _StripIcon(
      tooltip: [command.title, if (command.key case final k?) k.label].join('  '),
      onPressed: () => store.runPluginCommand(command),
      child: PluginGlyph(
        icon: command.icon,
        dir: store.plugins.byId(command.pluginId)?.dir,
        size: _StripIcon.glyph,
      ),
    );
  }
}

/// Um glifo de faixa: a engrenagem no cabeçalho e o par do rodapé. One box and
/// one glyph size for all of them — mismatched by a couple of pixels they read
/// as loose buttons instead of one control cluster.
///
/// O que o rodapé mudou não foi [glyph], foi [box]: 30px de alvo era o que
/// cabia quando três botões saíam da largura da busca. Com dois deles embaixo
/// sobra folga pra um alvo de 36 nas duas faixas — inclusive no cabeçalho, que
/// agora paga por uma engrenagem em vez de três glifos.
///
/// Todos os três são `_outlined`. Antes eram dois cheios e um vazado, que é o
/// que fazia a fileira parecer três ícones emprestados de lugares diferentes:
/// numa barra de ferramentas o que dá unidade não é o desenho, é a espessura
/// do traço ser a mesma em todos.
class _StripIcon extends StatelessWidget {
  const _StripIcon({this.icon, this.child, required this.tooltip, required this.onPressed})
    : assert(icon != null || child != null);

  /// O alvo do clique, e o que [_Footer] mede a fileira por. A faixa fica nos
  /// 42 do header — duas bordas do mesmo tamanho encapando a lista —, então o
  /// alvo é a folga que sobra dentro dela.
  static const box = 36.0;

  /// O desenho dentro do alvo, e a única maneira de mexer na espessura dele: o
  /// traço do `_outlined` do Material é 2px fixos numa grade de 24, então um
  /// contorno mais fino é um contorno menor -- e é essa a briga: 22 engrossava
  /// a fileira, 16 sumia dentro do alvo. 18 é o meio, e é o melhor que se
  /// consegue enquanto peso e tamanho forem o mesmo número.
  ///
  /// O alvo é [box] e não segue este número: a mão pede 36, o olho pede 18.
  ///
  /// Quem quiser controlar a espessura de verdade tem que trocar a fonte de
  /// ícones -- ver a nota em [_Footer].
  static const glyph = 18.0;

  /// A distância entre um botão e o próximo. Sem ela os três alvos se tocam e
  /// a fileira lê como um bloco só; com ela lê como três coisas que fazem
  /// três coisas.
  static const gap = 4.0;

  final IconData? icon;

  /// Um desenho que não é um [IconData] -- o svg de um plugin. Ver
  /// [PluginGlyph].
  final Widget? child;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: glyph,
      // Menor que meio alvo de propósito: o círculo do hover tem 32 e flutua
      // dentro da faixa, em vez de raspar as bordas de cima e de baixo.
      splashRadius: 16,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: box, height: box),
      padding: EdgeInsets.zero,
      icon: child ?? Icon(icon, color: Mx.fgDim),
      onPressed: onPressed,
    );
  }
}

/// A folder and everything under it. Never the loose tray — that is
/// [_LooseTray], which is not a folder and stopped pretending to be one.
class _FolderGroup extends StatelessWidget {
  const _FolderGroup({super.key, required this.store, required this.folder, this.within});
  final AppStore store;
  final Folder folder;

  /// O workspace em que esta aparição está desenhada; null na raiz. A mesma
  /// pasta aparece uma vez em cada workspace dela.
  final Workspace? within;

  @override
  Widget build(BuildContext context) {
    // Panels that belong to a project are drawn inside it, not twice. Com uma
    // busca em curso é só o que ela achou -- e um projeto sem achado sai junto.
    final featuresOrHotfixes = store
        .featuresOrHotfixesOf(folder)
        .where((p) => !store.filtering || store.visible(store.tabsIn(p)).isNotEmpty)
        .toList();
    final tabs = store.visible(store.tabsOf(folder).where((t) => t.featureOrHotfixId == null));
    final all = store.worktrees[folder.root] ?? const <WorktreeInfo>[];
    // Only the repo's own worktrees. Claude Code keeps transient ones under
    // ~/.local/state, and offering to do anything to one of those is offering
    // something that fails: they belong to the session that made them.
    //
    // They are not a row in the tree any more: five branches nobody is
    // touching right now are reference material, and a drawer of it sat in the
    // sidebar every day to be opened about once a week. What the repo *has*
    // lives behind the header now -- right-click, or the ⋯ -- and the tree is
    // only what is running. So the search no longer has to hide them either.
    final worktrees = all.where((w) => w.path.startsWith(folder.root)).toList();
    final ghosts = worktrees.where((w) => w.prunable).length;
    final alerts = store.needingHuman(folder);
    // Dobrada, uma pasta esconderia o que a busca acabou de achar nela. O que
    // você escolheu continua guardado -- só não vale enquanto se procura.
    //
    // A dobra é da aparição, não da pasta: espelhada em dois workspaces, ela
    // dobra num e continua aberta no outro.
    final collapsed = store.isFolderCollapsed(folder, within: within) && !store.filtering;
    // Sem cor própria, a pasta veste a do workspace em que está desenhada --
    // é o que diz, na linha dela, de que grupo ela é.
    final tint = folder.tint?.color ?? within?.tint?.color;
    final count = store.filtering
        ? store.visible(store.tabsOf(folder)).length
        : store.tabsOf(folder).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The + rides on the header instead of a strip of chips under every
        // folder: one target per row, and what it can start is in its menu.
        //
        // E é por ele que a pasta se arrasta pra outro lugar da lista. Ver
        // [_RowDrag].
        _RowDrag(
          store: store,
          place: (row: folder, within: within),
          child: _Hoverable(
            builder: (hovered) => InkWell(
              onTap: () => store.toggleFolderCollapsed(folder, within: within),
              // The whole header is the target the worktrees hang off now, not
              // just the ⋯ at the end of it.
              onSecondaryTapDown: (d) =>
                  showFolderMenu(
                    context,
                    store,
                    folder,
                    worktrees,
                    d.globalPosition,
                    within: within,
                  ),
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
                    // Na cor da pasta quando ela tem uma: é o fundo do repo
                    // dito na linha que abre o repo. Ver [MxTint].
                    RepoGlyph(isRepo: folder.isRepo, color: tint),
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
                    // The one thing in the worktree list that wants doing stays
                    // on the surface: registrations git itself would prune. The
                    // list is behind a menu now, and a warning you only meet by
                    // opening a menu is a warning that never arrives.
                    if (ghosts > 0) ...[_GhostChip(count: ghosts), const SizedBox(width: 7)],
                    if (alerts > 0) _Badge(count: alerts),
                    Text('$count', style: TextStyle(color: Mx.fgFaint, fontSize: 11.5)),
                    _AddButton(
                      store: store,
                      folder: folder,
                      // An empty folder has no rows to hover over, so the + is
                      // the only thing left to aim at: it stays out.
                      shown: hovered || store.tabsOf(folder).isEmpty,
                    ),
                    _FolderMenu(store: store, folder: folder, worktrees: worktrees, within: within),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (!collapsed)
          _Nest(
            // Como a do projeto: a trilha diz de que pasta é o que está
            // pendurado nela.
            color: tint,
            children: [
              for (final p in featuresOrHotfixes)
                _FeatureOrHotfixGroup(key: ValueKey(p.id), store: store, folder: folder, featureOrHotfix: p),
              ..._panelRows(store, tabs),
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
///
/// Os projetos da bandeja são a exceção, e não voltam atrás nisso: um projeto
/// *é* uma coisa em que os painéis dele estão, então ele traz o próprio
/// cabeçalho e o próprio degrau. A régua continua não sendo pasta -- ela só
/// deixou de ser a única forma de arrumar o que está embaixo dela.
class _LooseTray extends StatelessWidget {
  const _LooseTray({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final folder = store.loose;
    // Ver [_FolderGroup]: painel de projeto se desenha dentro dele e não duas
    // vezes, e projeto sem achado sai da lateral enquanto a busca durar.
    final featuresOrHotfixes = store
        .featuresOrHotfixesOf(folder)
        .where((p) => !store.filtering || store.visible(store.tabsIn(p)).isNotEmpty)
        .toList();
    final tabs = store.visible(store.tabsOf(folder).where((t) => t.featureOrHotfixId == null));
    final alerts = store.needingHuman(folder);
    // Tudo que está na bandeja, projetos inclusive -- o número na régua conta
    // o lugar, e não a lista de linhas soltas que por acaso vem embaixo dela.
    final count = store.filtering
        ? store.visible(store.tabsOf(folder)).length
        : store.tabsOf(folder).length;
    // O que a varrida levaria. Zero e o "limpar" da régua não existe: um
    // botão que não tem o que limpar é um botão que não faz nada. Com uma
    // busca em curso ele também sai: varrer ali fecharia painéis que a busca
    // está escondendo, e ninguém limpa o que não está vendo.
    final settled = store.filtering ? 0 : store.settledIn(folder);

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
                if (count > 0) ...[
                  const SizedBox(width: 8),
                  Text('$count', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                ],
                const SizedBox(width: 6),
                // O mesmo "limpar concluídos" do ⋯, na régua: é a varrida que
                // se faz toda hora aqui -- a bandeja é onde as sessões de uma
                // tarde se acumulam --, e ela não merecia dois cliques e um
                // menu. Só aparece quando há o que varrer.
                if (settled > 0)
                  _ClearButton(
                    tooltip: settled == 1
                        ? 'limpar 1 painel concluído'
                        : 'limpar $settled painéis concluídos',
                    shown: hovered,
                    onTap: () => _sweep(store, folder),
                  ),
                _AddButton(
                  store: store,
                  folder: folder,
                  shown: hovered || (tabs.isEmpty && featuresOrHotfixes.isEmpty),
                ),
                _LooseMenu(store: store),
              ],
            ),
          ),
        ),
        // Os projetos primeiro e as linhas soltas depois, como numa pasta: o
        // que tem nome vem antes do que sobrou.
        for (final p in featuresOrHotfixes)
          _FeatureOrHotfixGroup(key: ValueKey(p.id), store: store, folder: folder, featureOrHotfix: p),
        ..._panelRows(store, tabs),
      ],
    );
  }
}

/// O cabeçalho de uma aba de plugin: o desenho e o nome dele, no lugar da
/// busca. Os mesmos 42 do [_Header], pra borda de cima não pular quando a aba
/// troca.
///
/// A engrenagem leva às configurações dos plugins, e não às da janela: aqui
/// dentro, "configurar" quer dizer configurar isto.
class _PluginHeader extends StatelessWidget {
  const _PluginHeader({required this.store, required this.plugin});
  final AppStore store;
  final MxPlugin plugin;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 42,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Mx.border)),
      ),
      child: Row(
        children: [
          PluginGlyph(icon: plugin.manifest?.icon, dir: plugin.dir, size: 15, color: Mx.fgDim),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              plugin.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
            ),
          ),
          _StripIcon(
            icon: Icons.settings_outlined,
            tooltip: 'configurar os plugins',
            onPressed: () => showSettings(context, store, section: MxSection.plugins),
          ),
        ],
      ),
    );
  }
}

/// O miolo de uma aba de plugin: as janelas que ele abriu e, embaixo, o que
/// ele sabe fazer.
///
/// Os comandos são o que faz a aba valer um clique. Só com as janelas, a aba
/// do SSH seria uma lateral inteira pra uma linha; com eles, ela é o lugar
/// onde se conecta a um host mesmo sem nada aberto -- os mesmos comandos do
/// menu do painel e da paleta, à vista em vez de lembrados.
class _PluginPage extends StatelessWidget {
  const _PluginPage({super.key, required this.store, required this.plugin});
  final AppStore store;
  final MxPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final tabs = store.viewsOf(plugin);
    // Quem desenha a aba desenha também os terminais dele (o ssh, cada host
    // com as conexões abertas); a aba genérica os lista junto das janelas.
    if (plugin.manifest?.sidebar == true) return _ownPage(tabs);
    tabs.addAll(store.ownedBy(plugin));
    final commands = plugin.active ? plugin.manifest!.commands : const <PluginCommand>[];
    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 20),
      children: [
        _PluginRuler(
          label: 'janelas',
          count: tabs.length,
          onClear: tabs.isEmpty
              ? null
              : () {
                  for (final t in [...tabs]) {
                    store.closeTab(t);
                  }
                },
          clearTooltip: tabs.length == 1 ? 'fechar a janela' : 'fechar as ${tabs.length} janelas',
          first: true,
        ),
        if (tabs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(17, 8, 12, 4),
            child: Text(
              'nenhuma janela aberta',
              style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
            ),
          )
        else
          ..._panelRows(store, tabs),
        if (commands.isNotEmpty) ...[
          _PluginRuler(label: 'comandos', count: commands.length),
          const SizedBox(height: 4),
          for (final c in commands) _CommandRow(store: store, plugin: plugin, command: c),
        ],
      ],
    );
  }

  /// A aba que o próprio plugin desenha (`contributes.sidebar`): os blocos que
  /// ele mandou por `sidebar.update`, no mesmo [PluginPane] das janelas.
  ///
  /// As janelas abertas ficam em cima, desenhadas daqui, e só quando existem:
  /// são painéis da janela -- achar e fechar um é coisa da Maestria, e o
  /// plugin não teria como saber qual está em foco.
  Widget _ownPage(List<MxTab> tabs) {
    final own = store.sidebarTabOf(plugin);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tabs.isNotEmpty) ...[
          _PluginRuler(
            label: 'janelas',
            count: tabs.length,
            first: true,
            clearTooltip: tabs.length == 1 ? 'fechar a janela' : 'fechar as ${tabs.length} janelas',
            onClear: () {
              for (final t in [...tabs]) {
                store.closeTab(t);
              }
            },
          ),
          ..._panelRows(store, tabs),
          const SizedBox(height: 6),
          Divider(height: 1, color: Mx.border),
        ],
        Expanded(
          child: own != null
              ? PluginPane(key: ValueKey(own.id), store: store, tab: own, bare: true)
              : _Waiting(store: store, plugin: plugin),
        ),
      ],
    );
  }
}

/// A aba própria de um plugin antes do primeiro `sidebar.update`: subindo, ou
/// caído sem ter desenhado nada.
class _Waiting extends StatelessWidget {
  const _Waiting({required this.store, required this.plugin});
  final AppStore store;
  final MxPlugin plugin;

  @override
  Widget build(BuildContext context) {
    final crashed = plugin.state == PluginState.crashed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 16, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!crashed) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Mx.fgFaint),
                ),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  crashed ? '${plugin.name} caiu: ${plugin.crash}' : 'abrindo ${plugin.name}…',
                  style: TextStyle(fontSize: 11.5, color: crashed ? Mx.red : Mx.fgFaint),
                ),
              ),
            ],
          ),
          if (crashed)
            TextButton(
              onPressed: () => store.plugins.restart(plugin),
              child: const Text('reiniciar'),
            ),
        ],
      ),
    );
  }
}

/// A régua de uma seção da aba de plugin -- o desenho da dos avulsos, que é o
/// outro lugar da lateral que não é uma pasta.
class _PluginRuler extends StatelessWidget {
  const _PluginRuler({
    required this.label,
    required this.count,
    this.onClear,
    this.clearTooltip = '',
    this.first = false,
  });

  final String label;
  final int count;
  final VoidCallback? onClear;
  final String clearTooltip;

  /// A primeira da lista não precisa do respiro que separa uma seção da de
  /// cima.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return _Hoverable(
      builder: (hovered) => Padding(
        padding: EdgeInsets.only(left: 17, right: 8, top: first ? 10 : 22),
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              Text(label, style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, letterSpacing: 0.5)),
              const SizedBox(width: 9),
              Expanded(child: Container(height: 1, color: Mx.border)),
              const SizedBox(width: 8),
              Text('$count', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
              if (onClear case final clear?) ...[
                const SizedBox(width: 6),
                _ClearButton(tooltip: clearTooltip, shown: hovered, onTap: clear),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Um comando do plugin como linha da aba: o desenho, o nome sem o prefixo
/// do plugin e a tecla, se houver.
///
/// O prefixo sai porque aqui ele é o cabeçalho: "flutter: hot reload" faz
/// sentido na paleta, no meio dos comandos de todo mundo; embaixo de
/// "Flutter" é o título dizendo a mesma coisa em cada linha.
class _CommandRow extends StatefulWidget {
  const _CommandRow({required this.store, required this.plugin, required this.command});
  final AppStore store;
  final MxPlugin plugin;
  final PluginCommand command;

  /// [title] sem o "nome do plugin: " da frente, quando é esse o prefixo.
  static String shortTitle(String title, String pluginName) {
    final colon = title.indexOf(': ');
    if (colon <= 0) return title;
    return title.substring(0, colon).toLowerCase() == pluginName.toLowerCase()
        ? title.substring(colon + 2)
        : title;
  }

  @override
  State<_CommandRow> createState() => _CommandRowState();
}

class _CommandRowState extends State<_CommandRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.command;
    final busy = widget.store.plugins.busy.contains(c.fullId);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : () => widget.store.runPluginCommand(c),
        child: Container(
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.only(left: 9, right: 8),
          decoration: BoxDecoration(
            color: _hover ? Mx.bgHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Mx.fgDim),
                        )
                      // O desenho do comando quando ele tem um; senão um ponto
                      // neutro, e não o logo do plugin repetido dez vezes. Nem
                      // a seta: na lateral ela é a das seções que abrem e
                      // fecham, e um comando não abre nada.
                      : c.icon != null
                      ? PluginGlyph(icon: c.icon, dir: widget.plugin.dir, size: 14, color: Mx.fgDim)
                      : Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(color: Mx.fgFaint, shape: BoxShape.circle),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _CommandRow.shortTitle(c.title, widget.plugin.name),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _hover ? Mx.fg : Mx.fgDim),
                ),
              ),
              if (c.key case final key?)
                Text(key.label, style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
            ],
          ),
        ),
      ),
    );
  }
}

/// O que se faz com a bandeja inteira. A [_FolderMenu] traria uma pasta de
/// opções — renomear, remover, git — pra um lugar onde nenhuma delas quer
/// dizer nada; sobram as duas que querem: nomear um trabalho aqui e limpar o
/// que já acabou.
class _LooseMenu extends StatelessWidget {
  const _LooseMenu({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return _RowButton(
      tooltip: 'o que fazer com os avulsos',
      icon: Icons.more_horiz,
      onTap: (anchor) async {
        final choice = await mxMenu<String>(
          context,
          at: anchor,
          items: [
            for (final kind in FeatureOrHotfixKind.values)
            mxItem(
              'new:${kind.name}',
              glyph: Icon(kind.icon, size: 14, color: Mx.purple),
              label: '${kind.newLabel}…',
            ),
            mxItem(
              'sweep',
              glyph: Icon(Icons.clear_all, size: 14, color: Mx.fgDim),
              label: 'limpar concluídos',
            ),
          ],
        );
        if (choice == null || !context.mounted) return;
        if (choice.startsWith('new:')) {
          await showNewFeatureOrHotfix(
            context,
            store,
            store.loose,
            kind: FeatureOrHotfixKind.byName(choice.substring(4)),
          );
          return;
        }
        if (choice == 'sweep') _sweep(store, store.loose);
      },
    );
  }
}

/// A varrida da bandeja, com o relato do que ela levou.
///
/// Uma definição pras duas portas -- o ⋯ e o "limpar" da régua --, e o relato
/// é por causa da segunda: quem clica num botão de limpar quer saber se ele
/// limpou, e uma linha que sai da lateral é fácil de não ver.
void _sweep(AppStore store, Folder folder) {
  final closed = store.closeSettled(folder);
  store.showBanner(
    closed == 0
        ? 'nada pra limpar aqui — nenhum painel marcado como concluído'
        : closed == 1
        ? 'um painel fechado — o que estava marcado como concluído'
        : '$closed painéis fechados — os que estavam marcados como concluídos',
  );
}

/// Os arranjos salvos, no alto da lateral. Ver [PaneGroup].
///
/// Fora das pastas porque um grupo não é um lugar onde sessões moram -- é uma
/// vista da tela, e os painéis dele continuam sendo das pastas e dos projetos
/// deles. E no alto porque é a linha que se clica pra voltar ao trabalho: ela
/// não pode ficar depois de vinte sessões.
///
/// Desenhado como a bandeja dos avulsos -- uma régua com uma palavra e as
/// linhas embaixo --, e pelo mesmo motivo: não há nada em que dobrar nem nada
/// dentro de que as linhas estejam.
///
/// Agrupar não se faz aqui: isso é o botão direito de um painel da grade. O
/// que só existe aqui é o que a linha de um painel não consegue oferecer --
/// abrir um grupo cujos painéis todos saíram da tela (não há linha acesa pra
/// clicar), renomear e esquecer.
///
/// Dobra, ao contrário da régua dos avulsos: aqui há sim onde guardar o que
/// está embaixo. Um grupo é uma vista que se abre num clique, e depois de
/// arrumada a vista as linhas dos grupos são o que está entre o alto da
/// lateral e as sessões -- então a régua fecha por cima delas e fica sendo o
/// que ela é nesse momento: uma palavra, um número, e o caminho de volta.
class _GroupTray extends StatelessWidget {
  const _GroupTray({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final collapsed = store.groupsCollapsed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hoverable(
          builder: (hovered) => InkWell(
            // A régua inteira dobra e desdobra, como o cabeçalho de uma pasta.
            onTap: store.toggleGroupsCollapsed,
            child: Padding(
              // O galho ocupa a calha à esquerda pra palavra continuar onde
              // ela estava -- alinhada com "avulsos", que é a outra régua.
              padding: const EdgeInsets.only(left: 4, right: 8, top: 4),
              child: Row(
                children: [
                  Icon(
                    collapsed ? Icons.chevron_right : Icons.expand_more,
                    size: 14,
                    color: Mx.fgFaint,
                  ),
                  Text(
                    'grupos',
                    style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, letterSpacing: 0.5),
                  ),
                  const SizedBox(width: 9),
                  Expanded(child: Container(height: 1, color: Mx.border)),
                  // Quantos são -- e dobrada, é o que a régua tem pra dizer
                  // sobre o que ela está escondendo.
                  const SizedBox(width: 8),
                  Text('${store.groups.length}', style: TextStyle(fontSize: 11, color: Mx.fgFaint)),
                  const SizedBox(width: 6),
                  _ClearButton(
                    tooltip: 'esquecer todos os grupos',
                    shown: hovered,
                    onTap: () => confirmClearGroups(context, store),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          for (final g in store.groups) _GroupRow(key: ValueKey(g.id), store: store, group: g),
        // A régua da primeira pasta vem logo abaixo; sem isto as duas se
        // encostam e a lista lê como uma coisa só.
        const SizedBox(height: 8),
      ],
    );
  }
}

/// Um arranjo salvo, numa linha. Clicar abre os painéis dele como estavam.
class _GroupRow extends StatelessWidget {
  const _GroupRow({super.key, required this.store, required this.group});
  final AppStore store;
  final PaneGroup group;

  @override
  Widget build(BuildContext context) {
    return _Row(
      // Acesa quando a tela é este grupo -- ver [AppStore.activeGroup]. É o
      // mesmo "está na tela" que acende a linha de uma sessão, e é o que faz
      // a cor ler como estado e não só como etiqueta.
      selected: store.showing(group),
      tint: group.color,
      // O glifo na cor do grupo é o que amarra esta linha às linhas dos
      // painéis dele, que estão lavadas da mesma cor lá embaixo.
      leading: Icon(Icons.grid_view_rounded, size: 17, color: group.color),
      title: group.name,
      // O que ele abre, contado: um nome sozinho não diz se aquele grupo é o
      // dos três terminais ou o do par claude-e-terminal. Quando o nome já é
      // esse resumo -- um grupo recém-agrupado se chama assim --, a linha diz
      // em vez disso onde aqueles painéis rodam.
      subtitle: group.name.toLowerCase() == group.summary.toLowerCase()
          ? group.where
          : group.summary,
      trailing: Row(
        children: [
          _CountChip(count: group.count),
          const SizedBox(width: 2),
          _GroupMenu(store: store, group: group),
        ],
      ),
      onTap: () => store.openGroup(group),
      onSecondary: (pos) => showGroupMenu(context, store, group, pos),
    );
  }
}

/// O ⋯ da linha de um grupo. Uma definição, duas entradas: este e o
/// botão direito da linha abrem o mesmo [showGroupMenu].
class _GroupMenu extends StatelessWidget {
  const _GroupMenu({required this.store, required this.group});
  final AppStore store;
  final PaneGroup group;

  @override
  Widget build(BuildContext context) {
    return _RowButton(
      tooltip: 'o que fazer com esse grupo',
      icon: Icons.more_horiz,
      onTap: (anchor) => showGroupMenu(context, store, group, anchor),
    );
  }
}

/// Tudo que se faz a um grupo. Abrir não está aqui: abrir é a linha.
Future<void> showGroupMenu(
  BuildContext context,
  AppStore store,
  PaneGroup group,
  Offset anchor,
) async {
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      mxItem(
        'update',
        glyph: Icon(Icons.grid_view_rounded, size: 14, color: group.color),
        label: 'guardar a tela de agora aqui',
      ),
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'renomear',
      ),
      mxItem(
        'remove',
        glyph: Icon(Icons.grid_off, size: 14, color: Mx.red),
        label: 'esquecer o grupo',
        color: Mx.red,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'update':
      // O mesmo caminho de salvar, com o nome que já existe: quem atualiza o
      // grupo no lugar é o próprio [AppStore.saveGroup].
      final saved = store.saveGroup(group.name);
      store.showBanner(
        saved == null
            ? 'não há nada na tela pra guardar no grupo "${group.name}"'
            : 'grupo "${saved.name}" agora é ${saved.summary}',
      );
    case 'rename':
      final name = await promptText(
        context,
        title: 'renomear grupo',
        initial: group.name,
        label: 'nome',
      );
      if (name != null) store.renameGroup(group, name);
    case 'remove':
      // Sem confirmação: esquecer o arranjo não fecha painel nenhum, e o que
      // se perde é a disposição -- que se salva de novo em dois cliques.
      store.removeGroup(group);
  }
}

/// A named job — inside a folder, or in the loose tray — with its panels
/// under it.
///
/// It looks like the worktree folder one level down and behaves like the
/// folder one level up, which is the point: the sidebar is now three deep —
/// where the code is, what it is for, and who is working on it. Na bandeja o
/// primeiro degrau não existe, e é a mesma linha sem nada por cima.
class _FeatureOrHotfixGroup extends StatelessWidget {
  const _FeatureOrHotfixGroup({
    super.key,
    required this.store,
    required this.folder,
    required this.featureOrHotfix,
  });

  final AppStore store;
  final Folder folder;
  final FeatureOrHotfix featureOrHotfix;

  @override
  Widget build(BuildContext context) {
    final tabs = store.visible(store.tabsIn(featureOrHotfix));
    final alerts = store.needingHumanIn(featureOrHotfix);
    // Ver [_FolderGroup]: durante a busca, o que está dobrado abre.
    final collapsed = featureOrHotfix.collapsed && !store.filtering;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Dropping a panel on the header is how it joins: the same drag that
        // reorders panels, aimed one row higher.
        _FeatureOrHotfixDrop(
          store: store,
          featureOrHotfix: featureOrHotfix,
          child: _Hoverable(
            builder: (hovered) => InkWell(
              onTap: () => store.toggleFeatureOrHotfixCollapsed(featureOrHotfix),
              onSecondaryTapDown: (d) =>
                  showFeatureOrHotfixMenu(context, store, folder, featureOrHotfix, d.globalPosition),
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
                    // Na cor do projeto quando ele tem uma: é a mesma marca
                    // roxa de sempre até alguém pintá-lo, e a partir daí é
                    // ela que diz de que projeto são os painéis pendurados
                    // aqui embaixo. Ver [MxTint].
                    Icon(featureOrHotfix.kind.icon, size: 15, color: featureOrHotfix.tint?.color ?? Mx.purple),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        featureOrHotfix.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    // A natureza só se escreve quando não é a de sempre: uma
                    // lista em que toda linha diz "feature" é uma lista em que
                    // a palavra não diz nada.
                    if (featureOrHotfix.kind == FeatureOrHotfixKind.hotfix)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          'hotfix',
                          style: TextStyle(fontSize: 10.5, color: Mx.fgFaint),
                        ),
                      ),
                    // The briefing is invisible by nature — it is in a system
                    // prompt you never see scroll by. This is the only place
                    // that says a project has one.
                    if (featureOrHotfix.brief.trim().isNotEmpty)
                      Tooltip(
                        message: featureOrHotfix.brief.trim(),
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
                      featureOrHotfix: featureOrHotfix,
                      shown: hovered || tabs.isEmpty,
                    ),
                    _RowButton(
                      tooltip: 'o que fazer com ${featureOrHotfix.kind.thisOne}',
                      icon: Icons.more_horiz,
                      onTap: (anchor) => showFeatureOrHotfixMenu(context, store, folder, featureOrHotfix, anchor),
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
            // A trilha é o que liga as sessões ao projeto delas; pintada, ela
            // diz de relance onde aquele bloco de cor começa e acaba.
            color: featureOrHotfix.tint?.color,
            children: [..._panelRows(store, tabs), const SizedBox(height: 4)],
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
class _FeatureOrHotfixDrop extends StatefulWidget {
  const _FeatureOrHotfixDrop({required this.store, required this.featureOrHotfix, required this.child});

  final AppStore store;
  final FeatureOrHotfix featureOrHotfix;
  final Widget child;

  @override
  State<_FeatureOrHotfixDrop> createState() => _FeatureOrHotfixDropState();
}

class _FeatureOrHotfixDropState extends State<_FeatureOrHotfixDrop> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<MxTab>(
      onWillAcceptWithDetails: (d) {
        if (d.data.folderRoot != widget.featureOrHotfix.folderRoot) return false;
        if (d.data.featureOrHotfixId == widget.featureOrHotfix.id) return false;
        setState(() => _over = true);
        return true;
      },
      onLeave: (_) {
        if (_over) setState(() => _over = false);
      },
      onAcceptWithDetails: (d) {
        setState(() => _over = false);
        widget.store.assign(d.data, widget.featureOrHotfix);
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

/// As linhas de uma lista de painéis, com o que nasceu de um fluxo pendurado
/// em quem o abriu.
///
/// Um fluxo produz painéis -- a sessão de revisão, o terminal do comando -- e
/// eles chegavam soltos: linhas seguidas, às vezes com o mesmo nome, e nada
/// dizendo que eram uma coisa só acontecendo. A ninhada entra um degrau
/// adentro, no mesmo trilho com que uma pasta segura os painéis dela (ver
/// [_Nest]), e recursivamente -- um fluxo que abre uma sessão que abre outra
/// desenha os dois níveis.
///
/// Só enquanto o filho vier logo atrás do pai na lista. Arrastar uma linha pra
/// outro lugar é dizer que ela vale sozinha, e aí ela volta a ser uma linha
/// como as outras -- sem estado escondido pra discordar do que se vê.
List<Widget> _panelRows(AppStore store, List<MxTab> tabs) {
  final rows = <Widget>[];
  for (var i = 0; i < tabs.length; i++) {
    final tab = tabs[i];
    rows.add(_TabRow(key: ValueKey(tab.id), store: store, tab: tab));
    final brood = <MxTab>[];
    while (i + 1 < tabs.length && store.descendsFrom(tabs[i + 1], tab)) {
      brood.add(tabs[++i]);
    }
    if (brood.isNotEmpty) {
      rows.add(_Nest(rail: 18, children: _panelRows(store, brood)));
    }
  }
  return rows;
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
    // O grupo a que este painel pertence, que é o que dá a cor da linha e o
    // que o clique nela faz. Ver [AppStore.groupOf].
    final group = store.groupOf(tab);
    final row = _Row(
      selected: selected,
      focused: focused,
      // A escolhida pro painel na frente da do grupo -- a regra mora na
      // store, com os outros três lugares que pintam. Ver [AppStore.tintOf].
      tint: store.tintOf(tab),
      // E mais forte quando foi escolhida -- pelo painel ou pelo projeto dele.
      // A cor de um grupo é uma etiqueta que junta linhas espalhadas e um
      // sussurro basta pra isso; a cor pedida existe pra um painel não ser
      // confundido com o vizinho, e aí sussurro nenhum serve.
      tintBold: store.chosenTintOf(tab) != null,
      // Concluída, a linha recua um passo: título apagado, marca apagada. Ela
      // continua ali — é uma sessão que você guardou de propósito — mas para
      // de disputar o olho com as que ainda estão trabalhando.
      //
      // Parada e já lida recua pelo mesmo motivo e um passo antes do tique: o
      // tique é o julgamento ("essa funcionou"), e antes dele já dá pra saber
      // que essa aqui não é novidade nenhuma -- você acabou de olhar pra ela.
      // É o que faz o painel que terminou agora ser o único aceso entre cinco
      // que dizem "pronto".
      // E hibernada recua também: é uma linha guardada, não uma pendência.
      dim: tab.done || (tab.rested && !tab.unseen) || tab.hibernated,
      // Quando ela parou, na ponta do subtítulo -- e em verde enquanto você
      // não tiver visto. Ver [MxTab.restedAt] e [MxTab.unseen].
      stamp: tab.restedAgo,
      stampColor: tab.unseen ? Mx.green : null,
      leading: switch (tab.kind) {
        TabKind.claude => ClaudeAvatar(status: tab.status, size: 26, dim: tab.done),
        // Um leitor na lista se distingue pelo que é: uma folha, não um
        // prompt esperando comando.
        TabKind.reader => Icon(Icons.article_outlined, size: 18, color: Mx.fgDim),
        // E a configuração pelos ajustes: é um painel de mexer em coisas.
        TabKind.setup => Icon(Icons.tune, size: 18, color: Mx.fgDim),
        // E a janela de plugin pela peça de quebra-cabeça: é o que o VS Code
        // e o resto do mundo usam pra "veio de uma extensão".
        TabKind.plugin => PluginGlyph(
          icon: store.plugins.byId(tab.view!.pluginId)?.manifest?.icon,
          dir: store.plugins.byId(tab.view!.pluginId)?.dir,
        ),
        // O terminal que subiu dentro de um programa se anuncia como o
        // programa: o `>_` é o prompt esperando comando, e ali não há prompt
        // nenhum -- há um btop rodando.
        //
        // O prompt vem dentro de uma tela cheia, e não como chevron solto,
        // por duas razões. Solto, ele é a mesma seta que abre as pastas e os
        // grupos duas linhas acima -- na lista, um `>` sozinho se lê como
        // "clique pra expandir". E sólido ele tem peso: ao lado da rajada do
        // claude, que enche os 26px dela, um contorno fino sumia.
        //
        // Por ser sólido é que vai a 22 e não aos 17 dos glifos de launcher:
        // o que precisa empatar é a mancha, não a caixa. Isso não desloca o
        // título -- o `leading` mora num slot de 34 centralizado.
        TabKind.shell => switch (tab.launcher) {
          final l? => Icon(l.icon.glyph, size: 17, color: l.color),
          null => MxIcon(MxIcons.terminal, size: 22, color: Mx.fgDim),
        },
      },
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
          // A lua diz o que o subtítulo diz, num relance: sem processo, de
          // propósito. Ver [MxTab.hibernated].
          if (tab.hibernated)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: Tooltip(
                message: 'hibernada — sem processo; clique pra retomar a conversa',
                child: Icon(Icons.bedtime_outlined, size: 13, color: Mx.fgFaint),
              ),
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
                MxChord.slot(index).label,
                style: TextStyle(fontFamily: Mx.mono, fontSize: 10.5, color: Mx.fgFaint),
              ),
            ),
          // Claude rows say their state on the badge stamped into the mark;
          // a shell has no badge, so it keeps the dot.
          if (tab.kind == TabKind.shell) StatusDot(status: tab.status, size: 9),
        ],
      ),
      // A linha de um painel agrupado abre o grupo inteiro, e não ela mesma:
      // é o que "se clicar em algum do grupo, abre o grupo" quer dizer -- e é
      // a volta do caminho que o clique numa linha de fora faz (ver
      // [AppStore.select], que desmancha a grade nesse caso).
      onTap: () => group == null ? store.select(tab) : store.openGroup(group),
      onClose: () => store.closeTab(tab),
      onSecondary: (pos) => showPanelMenu(context, store, tab, pos),
    );
    return _PanelDrag(store: store, tab: tab, child: row);
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
              feedback: _lifted(widget.child, box.maxWidth),
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
}

/// The row in the air: a piece of the sidebar, lifted off it.
///
/// It brings its own background because the overlay it flies in has none —
/// a row whose fill is transparent until you hover it would otherwise drag
/// across the terminal as loose text.
Widget _lifted(Widget child, double width) => Material(
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
      child: child,
    ),
  ),
);

/// A folder's glyph: a folder, plus — when the folder turned out to be a git
/// repo — the branch mark welded onto its corner. Together they say "repo
/// folder" without spending a word on it; a plain folder stays a plain folder.
class RepoGlyph extends StatelessWidget {
  const RepoGlyph({super.key, required this.isRepo, this.size = 17, this.color});
  final bool isRepo;
  final double size;

  /// A cor da pasta, quando ela tem uma. Só a pasta é pintada: o distintivo
  /// de branch continua roxo, porque ele não fala da pasta -- fala de git.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (!isRepo) {
      return Icon(Icons.folder_outlined, size: size, color: color ?? Mx.fgFaint);
    }
    return SizedBox(
      width: size + 3,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.folder_rounded, size: size, color: color ?? Mx.fgDim),
          Positioned(
            right: 0,
            bottom: -1,
            // A ring in the sidebar's own colour, so the mark reads as a badge
            // on the folder instead of a scratch across it. Na cor cheia e
            // não na translúcida: o anel existe pra tapar a pasta atrás dele,
            // e um anel de vidro deixaria o glifo aparecer por baixo do badge.
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

/// How many worktrees are behind the "worktrees" line, in a chip. Loose beside
/// the label the digit read as a stray character of it; boxed, it reads as a
/// quantity.
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
///
/// It rides on the repo header, and again on the line that opens the list: it
/// is the only part of the worktrees that asks for anything, so it is the only
/// part that did not go behind the menu.
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
  const _AddButton({required this.store, required this.folder, this.featureOrHotfix, required this.shown});

  final AppStore store;
  final Folder folder;

  /// Set on a project's header: what the menu starts joins that project and
  /// comes up with its briefing.
  final FeatureOrHotfix? featureOrHotfix;

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
          tooltip: featureOrHotfix != null
              ? 'abrir algo ${featureOrHotfix!.kind.inThis}'
              : folder.isLoose
              ? 'abrir algo sem pasta'
              : 'abrir algo nessa pasta',
          icon: Icons.add,
          onTap: (anchor) => _showAddMenu(context, store, folder, featureOrHotfix, anchor),
        ),
      ),
    );
  }
}

/// O "limpar" de uma régua: o gesto de esvaziar o que está embaixo dela.
///
/// Mesma mecânica do [_AddButton] -- espera o ponteiro, e invisível também é
/// inclicável --, e pelos mesmos motivos. São os dois lados de uma régua: o +
/// põe coisa ali, este tira.
class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.tooltip, required this.shown, required this.onTap});

  final String tooltip;
  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: shown ? 1 : 0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !shown,
        child: _RowButton(
          tooltip: tooltip,
          // A vassoura e não um x: um x numa régua leria como "fechar isto
          // aqui", e o que o botão faz é passar por cima do que está embaixo.
          icon: Icons.clear_all,
          onTap: (_) => onTap(),
        ),
      ),
    );
  }
}

/// What the + offers: [openHereItems], plus the one thing only the + has.
///
/// A bandeja dos avulsos oferece projeto como qualquer pasta. Ela não é uma
/// pasta, mas um projeto não é uma pasta tampouco: ele diz *para quê* as
/// sessões existem, e trabalho com nome que não mora em repo nenhum -- ler um
/// contrato, arrumar a máquina -- é exatamente o que cai ali. Um projeto é que
/// não pode conter um projeto, e ali a linha não aparece.
Future<void> _showAddMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  FeatureOrHotfix? featureOrHotfix,
  Offset anchor,
) async {
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      ...openHereItems(store),
      // Depois do risco porque não é abrir um painel: é dar nome ao trabalho
      // que os painéis vão fazer.
      if (featureOrHotfix == null) ...[
        mxDivider(),
        for (final kind in FeatureOrHotfixKind.values)
        mxItem(
          'new:${kind.name}',
          glyph: Icon(kind.icon, size: 14, color: Mx.purple),
          label: '${kind.label}…',
        ),
      ],
    ],
  );
  if (choice == null || !context.mounted) return;

  if (choice.startsWith('new:')) {
    await showNewFeatureOrHotfix(
      context,
      store,
      folder,
      kind: FeatureOrHotfixKind.byName(choice.substring(4)),
    );
    return;
  }
  await openHereChoice(context, store, choice, folder: folder, featureOrHotfix: featureOrHotfix);
}

/// The ⋯ on a repo header. One definition, two ways in: this and the header's
/// right-click both open [showFolderMenu], anchored where you clicked.
class _FolderMenu extends StatelessWidget {
  const _FolderMenu({
    required this.store,
    required this.folder,
    required this.worktrees,
    this.within,
  });
  final AppStore store;
  final Folder folder;
  final List<WorktreeInfo> worktrees;

  /// Ver [_FolderGroup.within].
  final Workspace? within;

  @override
  Widget build(BuildContext context) {
    return _RowButton(
      tooltip: 'o que fazer com essa pasta',
      icon: Icons.more_horiz,
      onTap: (anchor) =>
          showFolderMenu(context, store, folder, worktrees, anchor, within: within),
    );
  }
}

/// Everything you can do to a folder — abrir algo nela inclusive — e a porta
/// das worktrees.
///
/// The worktrees used to be a folded row inside the tree. Folded is where they
/// spent their life, so that row was a permanent line of sidebar paying for a
/// click almost nobody made; opened, five branches sat on top of the sessions.
/// Here the list costs nothing until it is asked for, and asking is the
/// gesture you already use on a folder.
///
/// E o menu abre com a mesma oferta do + da linha: o botão direito numa pasta
/// é o gesto de "quero fazer algo aqui", e o mais provável dos algos é abrir
/// uma sessão. Antes ele mandava você mirar num + de 18 pixels que só existe
/// com o ponteiro em cima da linha -- e o projeto e a worktree, que já traziam
/// o bloco, respondiam ao botão direito melhor do que a pasta. Ver
/// [openHereItems].
Future<void> showFolderMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  List<WorktreeInfo> worktrees,
  Offset anchor, {
  // O workspace da aparição em que o menu abriu; null na raiz. Quem o usa são
  // os itens de workspace do menu.
  Workspace? within,
}) async {
  final ghosts = worktrees.where((w) => w.prunable).length;
  // Every repo has a main checkout, so a repo with nothing else has a list of
  // one thing -- the folder you just right-clicked. The line only appears once
  // there is something in there you could not already see.
  final branched = worktrees.any((w) => !w.isMain);
  final choice = await mxMenu<String>(
    context,
    at: anchor,
    items: [
      // Abrir algo aqui primeiro: é o que se vem fazer numa pasta. Retomar
      // uma conversa não está no bloco -- foi 'conversas de antes…' e depois
      // 'retomar conversa…' neste menu, e hoje é o relógio do rodapé da
      // lateral, com esta pasta virando uma seção da lista de lá. Ver
      // [openHereItems].
      ...openHereItems(store),
      mxDivider(),
      // O que o Claude lê desta pasta, num painel que edita. Fora do bloco de
      // abrir porque não é abrir uma sessão: é arrumar a casa em que as
      // sessões vão rodar. Ver [AppStore.showSetup].
      mxItem(
        'setup',
        glyph: Icon(Icons.tune, size: 14, color: Mx.fgDim),
        label: 'configuração do claude',
      ),
      // Depois do bloco de abrir, porque abrir numa worktree é o que se
      // escolhe lá dentro: a linha é a mesma oferta sobre outro checkout, com
      // o que o repo *tem* dito de passagem -- quantas, e quantas fantasmas.
      if (branched)
        mxItem(
          'worktrees',
          glyph: Icon(Icons.call_split, size: 14, color: Mx.fgDim),
          label: 'worktrees',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CountChip(count: worktrees.length),
              if (ghosts > 0) ...[const SizedBox(width: 6), _GhostChip(count: ghosts)],
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, size: 14, color: Mx.fgFaint),
            ],
          ),
        ),
      mxDivider(),
      // Dar nome às coisas -- e nada mais neste bloco: 'nova task…' saiu
      // porque tem atalho ([MxAction.newTask]) e porque o menu do projeto é
      // onde ela quase sempre é pedida, e 'atualizar git' saiu porque o
      // `refreshGit` já roda de dez em dez segundos sozinho (ver
      // [AppStore.start]) -- uma linha de menu pra pedir o que acontece de
      // graça é uma linha que só ensina a duvidar dela.
      for (final kind in FeatureOrHotfixKind.values)
      mxItem(
        'new:${kind.name}',
        glyph: Icon(kind.icon, size: 14, color: Mx.purple),
        label: '${kind.newLabel}…',
      ),
      mxItem(
        'rename',
        glyph: Icon(Icons.drive_file_rename_outline, size: 14, color: Mx.fgDim),
        label: 'renomear',
      ),
      // A mesma linha do menu do projeto e do painel, um andar acima de
      // todos: aqui ela é o fundo do repo -- vale pro painel que ninguém
      // pintou e que não é de projeto pintado. Ver [tintItem] e
      // [AppStore.chosenTintOf].
      tintItem(folder.tint),
      mxDivider(),
      // E o que tira coisas da lateral.
      mxItem(
        'sweep',
        glyph: Icon(Icons.clear_all, size: 14, color: Mx.fgDim),
        label: 'limpar concluídos',
      ),
      mxItem(
        'remove',
        glyph: Icon(Icons.folder_off_outlined, size: 14, color: Mx.red),
        label: 'remover pasta',
        color: Mx.red,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  // O que é do bloco de abrir se resolve nele; o resto é deste menu.
  if (await openHereChoice(context, store, choice, folder: folder)) return;
  if (!context.mounted) return;

  if (choice.startsWith('new:')) {
    await showNewFeatureOrHotfix(
      context,
      store,
      folder,
      kind: FeatureOrHotfixKind.byName(choice.substring(4)),
    );
    return;
  }

  switch (choice) {
    case 'setup':
      store.showSetup(folder: folder);
    case 'worktrees':
      await showWorktreesMenu(context, store, folder, worktrees, anchor);
    case 'rename':
      final name = await promptText(
        context,
        title: 'renomear pasta',
        initial: folder.name,
        label: 'nome',
      );
      if (name != null && name.trim().isNotEmpty) store.renameFolder(folder, name.trim());
    case final pick when isTintChoice(pick):
      store.setFolderTint(folder, tintPicked(pick));
    case 'sweep':
      store.closeSettled(folder);
    case 'remove':
      await store.removeFolder(folder);
  }
}

/// The repo's worktrees, listed only when asked for: pick one and its own menu
/// opens where you picked it.
///
/// A picker rather than a set of actions, because there are four things you
/// might want from a worktree and [showWorktreeMenu] already spells them out —
/// including the one that deletes it, which is not something a list you are
/// only browsing should be one stray click away from.
///
/// Ghosts are the exception: cleaning them up is about the list, not about any
/// one row in it, so it sits at the bottom of the list itself.
Future<void> showWorktreesMenu(
  BuildContext context,
  AppStore store,
  Folder folder,
  List<WorktreeInfo> worktrees,
  Offset anchor,
) async {
  final ghosts = worktrees.where((w) => w.prunable).length;
  final choice = await mxMenu<String>(
    context,
    // Stepped off the line that opened it, so the second menu does not land on
    // top of the first and read as the same one redrawn.
    at: anchor + const Offset(14, 6),
    items: [
      for (final w in worktrees)
        mxItem(
          // The path is the identity: two worktrees can sit on branches with
          // the same short label, never in the same folder.
          w.path,
          glyph: Icon(
            w.prunable
                ? Icons.link_off
                : w.isMain
                ? Icons.home_outlined
                : Icons.call_split,
            size: 14,
            color: w.prunable ? Mx.yellow : Mx.fgFaint,
          ),
          label: w.isMain ? folder.name : w.shortLabel,
          // Duas linhas, porque um menu tem uns 216 de largura e um rótulo ao
          // lado de `feature/TASK#47730` não cabe numa -- e o branch é justo a
          // metade que seria cortada, e a que identifica a worktree. Ver
          // [mxMenuRow].
          subtitle: w.prunable
              ? 'sem pasta no disco'
              : store.tabAt(w.path) != null
              ? '${w.branch} · sessão aberta'
              : w.branch,
          // O amarelo é o que a linha tem pra dizer que aquela pasta não
          // existe mais: sem ele a fantasma lê como uma worktree qualquer.
          subtitleColor: w.prunable ? Mx.yellow : null,
        ),
      if (ghosts > 0) ...[
        mxDivider(),
        mxItem(
          'prune',
          glyph: Icon(Icons.cleaning_services_outlined, size: 14, color: Mx.yellow),
          label: 'limpar worktrees fantasmas',
          color: Mx.yellow,
        ),
      ],
    ],
  );
  if (choice == null || !context.mounted) return;

  if (choice == 'prune') {
    await store.pruneWorktrees(folder);
    return;
  }
  final picked = worktrees.firstWhere((w) => w.path == choice);
  await showWorktreeMenu(context, store, folder, picked, anchor + const Offset(28, 12));
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
  const _Nest({required this.children, this.rail = 20, this.color});

  final List<Widget> children;

  /// A cor da trilha, quando quem ela segura tem uma. Null é o fio de sempre.
  final Color? color;

  /// Where the rail falls, measured from the parent row's left edge. A folder
  /// header's chevron sits at x=10 and is 20 wide, so 20 lands on its centre.
  final double rail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(left: rail),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color ?? Mx.border)),
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
    this.tint,
    this.tintBold = false,
    this.stamp,
    this.stampColor,
  });

  final bool selected;
  final bool focused;
  final bool dim;

  /// A cor com que esta linha se lava, quando tem uma: a que alguém escolheu
  /// pro painel, ou a do grupo a que ele pertence. Ver [_TabRow], [MxTint] e
  /// `PaneGroup.color`.
  final Color? tint;

  /// Quanto dela entra: a escolhida à mão vai pesada, a deduzida vai leve.
  /// Ver [_TabRow].
  final bool tintBold;
  final Widget leading;
  final String title;
  final String subtitle;

  /// A idade que fica na ponta direita do subtítulo, quando a linha tem uma.
  ///
  /// Fora do próprio subtítulo de propósito: o subtítulo é a frase que a
  /// sessão disse por último e quase sempre está sendo cortada por "…" -- uma
  /// idade grudada no fim dela seria a primeira coisa a sumir, e é justamente
  /// a que não pode.
  final String? stamp;

  /// A cor dele, que é onde "você ainda não viu isso" é dito. Ver
  /// [MxTab.unseen].
  final Color? stampColor;
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
    final grey = widget.selected
        ? (widget.focused ? Mx.bgActive : Mx.bgHover)
        : (_hovered ? Mx.bgHover : Colors.transparent);
    // A cor do grupo entra como banho por cima desse cinza, e não no lugar
    // dele: os três degraus de aceso continuam sendo os três degraus, e o que
    // muda é o *tom* de todos eles -- que é o que faz três linhas espalhadas
    // por duas pastas lerem como um conjunto. Nenhum outro canal da linha é
    // colorido, então o fundo é o único lugar onde uma cor de etiqueta não
    // rouba o sentido de um estado: o tique de concluída, o ponto de dirty e
    // o badge de pendência continuam dizendo o que diziam.
    final background = widget.tint == null
        ? grey
        : Color.alphaBlend(
            widget.tint!.withValues(
              alpha: widget.tintBold
                  ? (widget.selected ? 0.4 : 0.26)
                  : (widget.selected ? 0.2 : 0.11),
            ),
            // Transparente não se mistura: sobre uma linha apagada o banho
            // vai por cima do fundo da lateral, que é o que está atrás dela.
            grey == Colors.transparent ? Mx.bgSidebar : grey,
          );
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
                      if (widget.subtitle.isNotEmpty || widget.stamp != null) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.subtitle,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: TextStyle(fontSize: 12, color: Mx.fgFaint),
                              ),
                            ),
                            if (widget.stamp case final age?) ...[
                              const SizedBox(width: 7),
                              Text(
                                age,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: widget.stampColor ?? Mx.fgFaint,
                                  fontWeight: widget.stampColor == null
                                      ? FontWeight.w400
                                      : FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
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
        'ou use o + no rodapé pra adicionar um repo.\n\npra abrir um painel sem pasta '
        'nenhuma, o + na linha de "avulsos" logo abaixo.',
        style: TextStyle(color: Mx.fgFaint, fontSize: 12.5, height: 1.55),
      ),
    );
  }
}
