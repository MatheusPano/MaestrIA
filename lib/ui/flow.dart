import 'package:flutter/material.dart';

import '../models.dart';
import '../services/store.dart';
import '../theme.dart';
import 'claude_mark.dart';

/// O editor de fluxo: o que acontece depois que uma sessão termina, e -- quando
/// não há sessão nenhuma ainda -- a sessão que abre o fluxo.
///
/// Era um `AlertDialog` com uma pilha de campos e um dropdown por passo, e ele
/// lia como um formulário: nada nele dizia que aquilo era uma coisa atrás da
/// outra. Um fluxo é uma linha do tempo, então a tela é uma linha -- o gatilho
/// em cima, os passos pendurados numa trilha, cada um sabendo dizer o que faz
/// e onde o texto que você digita vai parar.
///
/// A outra metade da mudança é [showNewFlow]. Um fluxo não precisa de painel
/// pra existir: o primeiro passo pode ser *abrir* a sessão, com o prompt dela
/// escrito aqui, e a fila já pendurada antes de ela dar o primeiro sinal.

/// Arma um painel que já existe.
Future<void> showFlow(BuildContext context, AppStore store, MxTab tab) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x66000000),
      builder: (_) => _FlowEditor(store: store, tab: tab, folder: tab.folder, cwd: tab.cwd),
    );

/// Monta um fluxo do zero, num lugar: a sessão inicial nasce com ele.
Future<void> showNewFlow(
  BuildContext context,
  AppStore store, {
  required Folder folder,
  String? cwd,
  Project? project,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x66000000),
  builder: (_) => _FlowEditor(
    store: store,
    folder: folder,
    cwd: cwd ?? folder.root,
    project: project,
  ),
);

/// O prompt que vale a pena vir escrito: uma sessão nova que lê o diff que a
/// anterior deixou. Nova é o ponto -- ela julga o trabalho, não o raciocínio
/// que levou até ele.
const _reviewPrompt =
    'Revise o que acabou de ser feito nesta worktree: leia `git status` e '
    '`git diff`, procure bugs, regressões e coisas fora do padrão do repo. '
    'Não altere nada — só relate o que achou.';

/// Um passo em edição. O controller é a razão de a lista ser rascunhada em
/// estado e só virar [FollowUp] no fim.
class _Draft {
  _Draft(this.kind, {String text = '', this.targetTabId})
    : text = TextEditingController(text: text);

  FollowUpKind kind;
  final TextEditingController text;
  String? targetTabId;

  /// O passo está pronto pra virar um [FollowUp]?
  ///
  /// Um "passar a bola" carrega o recado final da sessão sozinho, então ele é
  /// o único que é um passo inteiro sem nada digitado -- mas só depois de
  /// saber pra onde vai.
  bool get filled =>
      kind == FollowUpKind.handoff ? targetTabId != null : text.text.trim().isNotEmpty;

  FollowUp get step =>
      FollowUp(kind: kind, text: text.text.trim(), targetTabId: targetTabId);
}

class _FlowEditor extends StatefulWidget {
  const _FlowEditor({
    required this.store,
    required this.folder,
    required this.cwd,
    this.tab,
    this.project,
  });

  final AppStore store;

  /// O painel que o fluxo arma, quando ele já existe. Nulo é o fluxo que abre
  /// a própria sessão -- ver [showNewFlow].
  final MxTab? tab;
  final Folder folder;
  final String cwd;
  final Project? project;

  @override
  State<_FlowEditor> createState() => _FlowEditorState();
}

class _FlowEditorState extends State<_FlowEditor> {
  late final List<_Draft> _steps = [
    for (final f in widget.tab?.followUps ?? const <FollowUp>[])
      _Draft(f.kind, text: f.text, targetTabId: f.targetTabId),
  ];

  /// O prompt da sessão que o fluxo abre. Só existe no fluxo sem painel.
  final _opening = TextEditingController();

  /// Como o painel dessa sessão se chama. Vazio deixa o nome da pasta valer,
  /// que é o que [AppStore.openClaude] faz com um rótulo nulo.
  final _label = TextEditingController();

  bool get _fresh => widget.tab == null;

  /// Os painéis vivos do claude na mesma pasta: passar a bola é escrever no
  /// prompt de alguém, então precisa de um prompt pra escrever.
  List<MxTab> get _targets => widget.store.tabs
      .where(
        (t) =>
            t.id != widget.tab?.id &&
            t.kind == TabKind.claude &&
            !t.exited &&
            t.folderRoot == widget.folder.root,
      )
      .toList();

  @override
  void dispose() {
    for (final s in _steps) {
      s.text.dispose();
    }
    _opening.dispose();
    _label.dispose();
    super.dispose();
  }

  void _add(FollowUpKind kind, {int? at}) => setState(() {
    final draft = _Draft(kind, text: kind == FollowUpKind.newSession ? _reviewPrompt : '');
    _steps.insert(at ?? _steps.length, draft);
  });

  void _move(int from, int to) => setState(() {
    if (to < 0 || to >= _steps.length) return;
    _steps.insert(to, _steps.removeAt(from));
  });

  /// O fluxo pronto pra guardar: os passos que estão de pé, na ordem.
  List<FollowUp> get _ready => [
    for (final s in _steps)
      if (s.filled) s.step,
  ];

  bool get _canSave => _fresh ? _opening.text.trim().isNotEmpty : true;

  /// Onde a sessão do fluxo abre, dito como se lê: o menu que trouxe você aqui
  /// pode ter sido o de uma worktree, e "meu-repo" ali seria a pasta errada.
  String get _where {
    final root = widget.folder.root;
    if (widget.cwd == root || !widget.cwd.startsWith(root)) return widget.folder.name;
    return '${widget.folder.name}/${widget.cwd.split('/').last}';
  }

  void _save() {
    final steps = _ready;
    if (_fresh) {
      if (_opening.text.trim().isEmpty) return;
      widget.store.startFlow(
        folder: widget.folder,
        cwd: widget.cwd,
        project: widget.project,
        prompt: _opening.text.trim(),
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
        steps: steps,
      );
    } else {
      // Uma sessão já parada não vai virar ociosa de novo sozinha: sem o
      // `now` a fila armada sobre ela ficaria esperando um gatilho que já
      // passou. Ver [AppStore.queue].
      widget.store.queue(widget.tab!, steps, now: _idleNow);
    }
    Navigator.pop(context);
  }

  /// A sessão já está parada? É o que decide entre armar e disparar -- ver
  /// [ClaudeStatusUi.atRest].
  bool get _idleNow => widget.tab?.status.atRest ?? false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // O gatilho mostra o estado da sessão ao vivo: ela pode terminar com o
    // diálogo aberto, e é exatamente nessa hora que o texto do botão muda.
    animation: widget.store,
    builder: (context, _) => Dialog(
      backgroundColor: Mx.bgSidebar,
      insetPadding: const EdgeInsets.all(28),
      // O tamanho é um teto, não uma medida: a janela pode ser menor que o
      // diálogo que ela abriria, e um `SizedBox` fixo aqui estoura por baixo
      // -- a trilha some atrás do rodapé em vez de rolar.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    _trigger(),
                    for (var i = 0; i < _steps.length; i++) _card(i),
                    _adder(),
                  ],
                ),
              ),
              _footer(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _header() => Container(
    padding: const EdgeInsets.fromLTRB(20, 16, 16, 14),
    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mx.border))),
    child: Row(
      children: [
        Icon(Icons.account_tree_outlined, size: 16, color: Mx.purple),
        const SizedBox(width: 9),
        Text(
          _fresh ? 'novo fluxo' : 'fluxo',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Mx.fg),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _fresh
                ? 'em $_where'
                : '${_steps.length} '
                      '${_steps.length == 1 ? 'passo' : 'passos'} depois de '
                      '"${widget.tab!.title}"',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Mx.fgFaint),
          ),
        ),
        InkWell(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(Icons.close, size: 15, color: Mx.fgDim),
          ),
        ),
      ],
    ),
  );

  /// O cartão de cima: de onde o fluxo parte.
  Widget _trigger() => _Node(
    bullet: const _Bullet(child: ClaudeMark(size: 13)),
    tail: true,
    child: _Card(
      tinted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _fresh ? 'abre uma sessão em $_where' : 'quando essa sessão terminar',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Mx.fg),
          ),
          const SizedBox(height: 3),
          if (_fresh)
            Text(
              'ela é o primeiro passo: nasce com o prompt abaixo e o resto do '
              'fluxo já pendurado nela.',
              style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
            )
          else
            _standing(),
          if (_fresh) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _label,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (_) => setState(() {}),
              decoration: _decoration('como chamar o painel (opcional)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _opening,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(fontSize: 12.5),
              onChanged: (_) => setState(() {}),
              decoration: _decoration('o que pedir pra ela — o prompt de abertura'),
            ),
          ],
        ],
      ),
    ),
  );

  /// Como a sessão do gatilho está agora, e o que a fila está esperando dela.
  Widget _standing() {
    final tab = widget.tab!;
    final hold = widget.store.holdFor(tab);
    final forks = tab.hooks.forksOut;
    return Row(
      children: [
        Icon(Icons.circle, size: 7, color: tab.status.color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '${tab.title} · ${tab.status.label}'
            '${forks > 0 ? ' · $forks ${forks == 1 ? 'agente' : 'agentes'} rodando' : ''}'
            '${tab.armed && hold != FlowHold.go ? ' · ${hold.label}' : ''}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
          ),
        ),
      ],
    );
  }

  Widget _card(int i) {
    final step = _steps[i];
    return _Node(
      bullet: _Bullet(
        child: Text(
          '${i + 1}',
          style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.accent),
        ),
      ),
      tail: true,
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final k in FollowUpKind.values)
                        if (k != FollowUpKind.handoff || _targets.isNotEmpty)
                          _KindTile(
                            kind: k,
                            on: step.kind == k,
                            onTap: () => setState(() => step.kind = k),
                          ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _Tool(
                  icon: Icons.keyboard_arrow_up,
                  tip: 'subir',
                  onTap: i == 0 ? null : () => _move(i, i - 1),
                ),
                _Tool(
                  icon: Icons.keyboard_arrow_down,
                  tip: 'descer',
                  onTap: i == _steps.length - 1 ? null : () => _move(i, i + 1),
                ),
                _Tool(
                  icon: Icons.close,
                  tip: 'tirar do fluxo',
                  onTap: () => setState(() => _steps.removeAt(i).text.dispose()),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(step.kind.blurb, style: TextStyle(fontSize: 11.5, color: Mx.fgFaint)),
            if (step.kind == FollowUpKind.handoff) ...[
              const SizedBox(height: 6),
              _targetPicker(step),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: step.text,
              minLines: step.kind == FollowUpKind.command ? 1 : 3,
              maxLines: 8,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: step.kind == FollowUpKind.command ? Mx.mono : null,
              ),
              onChanged: (_) => setState(() {}),
              decoration: _decoration(step.kind.hint),
            ),
          ],
        ),
      ),
    );
  }

  Widget _targetPicker(_Draft step) {
    final targets = _targets;
    // O painel escolhido pode ter fechado com o diálogo aberto: um valor que
    // não está mais na lista faz o [DropdownButton] estourar, então some.
    final chosen = targets.any((t) => t.id == step.targetTabId) ? step.targetTabId : null;
    return Row(
      children: [
        Icon(Icons.arrow_right_alt, size: 16, color: Mx.fgFaint),
        const SizedBox(width: 6),
        DropdownButton<String>(
          value: chosen,
          hint: Text('pra qual painel', style: TextStyle(fontSize: 12, color: Mx.fgFaint)),
          isDense: true,
          underline: const SizedBox.shrink(),
          dropdownColor: Mx.bgActive,
          style: TextStyle(fontSize: 12, color: Mx.fg),
          items: [
            for (final t in targets) DropdownMenuItem(value: t.id, child: Text(t.title)),
          ],
          onChanged: (id) => setState(() => step.targetTabId = id),
        ),
      ],
    );
  }

  /// O pé da trilha: as quatro coisas que um passo pode ser.
  ///
  /// Sempre as quatro, e sempre inteiras -- com desenho, nome e uma linha do
  /// que fazem. Com a lista vazia elas são a pergunta "por onde começa"; com
  /// ela cheia, o "e depois". Um estado vazio separado diria as mesmas quatro
  /// coisas com outras palavras.
  Widget _adder() => _Node(
    bullet: _Bullet(dim: true, child: Icon(Icons.add, size: 13, color: Mx.fgDim)),
    tail: false,
    child: Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _steps.isEmpty ? 'por onde o fluxo começa?' : 'e depois?',
            style: TextStyle(fontSize: 12, color: Mx.fgDim),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in FollowUpKind.values)
                if (k != FollowUpKind.handoff || _targets.isNotEmpty)
                  _AddTile(kind: k, onTap: () => _add(k)),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _footer() => Container(
    padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
    decoration: BoxDecoration(border: Border(top: BorderSide(color: Mx.border))),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _rule,
            style: TextStyle(fontSize: 11, color: Mx.fgFaint, height: 1.35),
          ),
        ),
        const SizedBox(width: 14),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('cancelar')),
        const SizedBox(width: 4),
        FilledButton(onPressed: _canSave ? _save : null, child: Text(_verb)),
      ],
    ),
  );

  /// A regra, escrita onde ela vale. A parte que o usuário não tem como
  /// adivinhar é a do meio: "terminar" aqui não é "ficou ocioso".
  String get _rule => _fresh
      ? 'a sessão abre com o prompt acima; o passo 1 sai quando ela terminar de '
            'verdade — turno encerrado, nenhum agente dela ainda rodando e alguns '
            'segundos de silêncio. A fila não sobrevive a fechar o app.'
      : 'um passo por vez: sai quando a sessão terminar de verdade — turno '
            'encerrado, nenhum agente dela ainda rodando e alguns segundos de '
            'silêncio. Passo que não devolve o turno pra ela (comando, sessão '
            'nova, passar a bola) já emenda no seguinte. A fila não sobrevive a '
            'fechar o app.';

  String get _verb {
    if (_fresh) return _ready.isEmpty ? 'abrir a sessão' : 'abrir e armar';
    if (_ready.isEmpty) return 'limpar a fila';
    return _idleNow ? 'disparar' : 'armar';
  }

  InputDecoration _decoration(String hint) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Mx.bg,
    border: const OutlineInputBorder(),
    hintText: hint,
    hintStyle: TextStyle(color: Mx.fgFaint, fontSize: 12),
  );
}

/// Um degrau da trilha: a bolinha, a linha que desce dela, e o cartão ao lado.
class _Node extends StatelessWidget {
  const _Node({required this.bullet, required this.child, required this.tail});

  final Widget bullet;
  final Widget child;

  /// Desenha a linha que liga este degrau ao de baixo. O último não tem.
  final bool tail;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 34,
          child: Column(
            children: [
              bullet,
              if (tail)
                Expanded(
                  child: Center(
                    child: Container(width: 1.5, height: double.infinity, color: Mx.border),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: child,
          ),
        ),
      ],
    ),
  );
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.child, this.dim = false});

  final Widget child;
  final bool dim;

  @override
  Widget build(BuildContext context) => Container(
    width: 24,
    height: 24,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: dim ? Mx.bg : Mx.bgActive,
      shape: BoxShape.circle,
      border: Border.all(color: Mx.border),
    ),
    child: child,
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.tinted = false});

  final Widget child;
  final bool tinted;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
    decoration: BoxDecoration(
      color: tinted ? Mx.bgActive : Mx.bg,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Mx.border),
    ),
    child: child,
  );
}

/// O seletor de tipo de um passo, que era um dropdown.
///
/// As quatro opções cabem na largura do cartão, e vê-las lado a lado é o que
/// deixa escolher *parecer* escolher: um dropdown esconde três das quatro
/// atrás de um clique, e as três escondidas são justamente as que ninguém
/// descobria que existiam.
class _KindTile extends StatelessWidget {
  const _KindTile({required this.kind, required this.on, required this.onTap});

  final FollowUpKind kind;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: on ? Mx.bgActive : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: on ? Mx.accent : Mx.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kind.icon, size: 13, color: on ? Mx.accent : Mx.fgDim),
            const SizedBox(width: 6),
            Text(
              kind.short,
              style: TextStyle(
                fontSize: 11.5,
                color: on ? Mx.fg : Mx.fgDim,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Uma das quatro ofertas do pé da trilha.
class _AddTile extends StatefulWidget {
  const _AddTile({required this.kind, required this.onTap});

  final FollowUpKind kind;
  final VoidCallback onTap;

  @override
  State<_AddTile> createState() => _AddTileState();
}

class _AddTileState extends State<_AddTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        width: 202,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        decoration: BoxDecoration(
          color: _hover ? Mx.bgActive : Mx.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _hover ? Mx.accent : Mx.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(widget.kind.icon, size: 13, color: _hover ? Mx.accent : Mx.fgDim),
                const SizedBox(width: 7),
                Text(
                  widget.kind.short,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _hover ? Mx.fg : Mx.fgDim,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              widget.kind.blurb,
              style: TextStyle(fontSize: 10.5, color: Mx.fgFaint, height: 1.25),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Um botãozinho de canto de cartão: subir, descer, tirar.
class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.tip, this.onTap});

  final IconData icon;
  final String tip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final off = onTap == null;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 15, color: off ? Mx.border : Mx.fgDim),
        ),
      ),
    );
  }
}
