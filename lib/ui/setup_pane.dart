import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/notify.dart';
import '../services/setup.dart';
import '../services/store.dart';
import '../theme.dart';
import 'dialogs.dart';
import 'doc_pane.dart';
import 'panel.dart';

/// Um painel de configuração: os arquivos que o Claude Code lê de uma pasta,
/// listados e editáveis, no lugar de um terminal.
///
/// É um painel como qualquer outro -- mesma moldura, mesmo cabeçalho de 42px,
/// mesma árvore de cortes, arrastável pela linha da lateral. Ver [DocPane],
/// que é o mesmo raciocínio: o que estes dois não têm é processo.
///
/// A razão de existir é a pergunta "o que dá pra configurar por projeto pro
/// Claude se sair melhor?". A resposta é uma lista curta de arquivos -- o
/// `CLAUDE.md`, o `settings.json`, as regras, as skills, os agentes, as
/// decisões -- que ninguém lembra de cabeça e que se editavam alternando pro
/// VS Code. Aqui a lista *é* a tela: à esquerda o que existe e o que poderia
/// existir, à direita o arquivo aberto, e uma frase em cima dele dizendo pra
/// que ele serve. Ver `services/setup.dart`, que é quem sabe dos arquivos.
class SetupPane extends StatefulWidget {
  const SetupPane({
    super.key,
    required this.store,
    required this.tab,
    this.focused = true,
    this.showFocus = false,
    this.onFocus,
  });

  final AppStore store;
  final MxTab tab;
  final bool focused;
  final bool showFocus;
  final VoidCallback? onFocus;

  @override
  State<SetupPane> createState() => _SetupPaneState();
}

class _SetupPaneState extends State<SetupPane> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _editor = FocusNode(debugLabel: 'setup editor');
  final ScrollController _list = ScrollController();

  List<SetupSlot> _slots = const [];

  /// O texto como ele estava no disco na última leitura. A diferença entre
  /// ele e o campo é o que "não salvo" quer dizer.
  String _disk = '';

  /// O texto como ele entrou no editor: o do disco, ou o modelo de um arquivo
  /// que não existe. A diferença entre ele e o campo é o que *você* digitou
  /// -- e é só isso que merece um aviso ao sair. Um modelo que você abriu só
  /// pra ler difere do disco (que não tem nada), mas não é uma alteração sua.
  String _loaded = '';

  /// O arquivo mudou por fora enquanto você tinha alterações aqui. As duas
  /// versões não se somam sozinhas: o painel avisa e deixa você escolher qual
  /// fica, em vez de sobrescrever uma com a outra sem dizer.
  bool _outside = false;

  Timer? _watch;

  /// Qual raiz está na tela. Um painel de configuração é um lugar e a pasta
  /// dentro dele pode trocar (ver [MxSetup.become]) -- sem isto, a segunda
  /// pasta herdaria a lista e o editor da primeira.
  String _showing = '';

  MxSetup get _setup => widget.tab.setup!;

  SetupSlot? get _slot {
    final rel = _setup.selected;
    if (rel == null) return null;
    for (final s in _slots) {
      if (s.rel == rel) return s;
    }
    // Um selecionado que a varredura não trouxe: um arquivo descoberto que
    // foi apagado por fora. Continua na tela como "não existe ainda", que é
    // o que ele é agora.
    return _phantom(rel);
  }

  /// O campo difere do disco: é o que o chip "não salvo" diz.
  bool get _dirty => _text.text != _disk;

  /// Você mexeu no texto desde que ele entrou no editor: é o que o aviso de
  /// sair sem salvar protege.
  bool get _edited => _text.text != _loaded;

  /// Mesmo tique do leitor, e pelo mesmo motivo: um editor que salva por
  /// rename troca o inode e leva um `File.watch` junto. Ver `doc_pane.dart`.
  static const _pulse = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTyped);
    _adopt();
  }

  @override
  void didUpdateWidget(SetupPane old) {
    super.didUpdateWidget(old);
    _adopt();
  }

  @override
  void dispose() {
    _watch?.cancel();
    _text.dispose();
    _editor.dispose();
    _list.dispose();
    super.dispose();
  }

  void _onTyped() {
    // O chip "não salvo" acende na primeira tecla, e só ele precisa do
    // rebuild: o campo se redesenha sozinho.
    if (mounted) setState(() {});
  }

  void _adopt() {
    if (_setup.root == _showing) return;
    _showing = _setup.root;
    _slots = ClaudeSetup.scan(_setup.root);
    _watch?.cancel();
    _watch = Timer.periodic(_pulse, (_) => _tick());
    unawaited(_load());
  }

  /// A varredura periódica: a lista acompanha o disco, e o arquivo aberto
  /// também -- enquanto você não tiver mexido nele.
  Future<void> _tick() async {
    final fresh = ClaudeSetup.scan(_setup.root);
    var changed = !_sameList(fresh, _slots);
    _slots = fresh;
    final rel = _setup.selected;
    if (rel != null) {
      final now = await ClaudeSetup.read(_setup.root, rel);
      if (now != _disk) {
        if (_edited) {
          _outside = true;
        } else {
          _disk = now;
          _loaded = now;
          _text.text = now;
        }
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  static bool _sameList(List<SetupSlot> a, List<SetupSlot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].rel != b[i].rel || a[i].exists != b[i].exists) return false;
    }
    return true;
  }

  /// Põe o arquivo selecionado no editor. Um que não existe abre com o
  /// modelo dele já escrito: salvar é o que o cria, e a primeira coisa a
  /// fazer num arquivo novo é raramente encarar uma tela branca.
  Future<void> _load() async {
    final slot = _slot;
    _outside = false;
    if (slot == null) {
      _disk = '';
      _loaded = '';
      _text.text = '';
      if (mounted) setState(() {});
      return;
    }
    if (slot.exists) {
      _disk = await ClaudeSetup.read(_setup.root, slot.rel);
      _loaded = _disk;
    } else {
      _disk = '';
      _loaded = ClaudeSetup.template(slot.rel, folderName: _setup.name);
    }
    _text.text = _loaded;
    if (mounted) setState(() {});
  }

  SetupSlot _phantom(String rel) {
    final section = rel.startsWith('.claude/rules/')
        ? SetupSection.rules
        : rel.startsWith('.claude/skills/') || rel.startsWith('.claude/commands/')
        ? SetupSection.skills
        : rel.startsWith('.claude/agents/')
        ? SetupSection.agents
        : rel.startsWith('docs/adr/')
        ? SetupSection.decisions
        : rel.endsWith('.json')
        ? SetupSection.settings
        : SetupSection.memory;
    return SetupSlot(
      section: section,
      rel: rel,
      label: rel.split('/').last,
      about: section.about,
      exists: File(ClaudeSetup.pathOf(_setup.root, rel)).existsSync(),
    );
  }

  Future<void> _select(String rel) async {
    if (rel == _setup.selected) {
      _editor.requestFocus();
      return;
    }
    if (_edited && _slot != null && !await _confirmDiscard()) return;
    _setup.selected = rel;
    widget.store.touch();
    await _load();
    _editor.requestFocus();
  }

  Future<bool> _confirmDiscard() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: Text('descartar o que mudou em ${_slot?.label}?', style: const TextStyle(fontSize: 15)),
        content: Text(
          'o arquivo não foi salvo. sair dele agora perde o que você escreveu.',
          style: TextStyle(fontSize: 12.5, color: Mx.fgDim),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('voltar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Mx.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('descartar'),
          ),
        ],
      ),
    );
    return go == true;
  }

  Future<void> _save() async {
    final slot = _slot;
    if (slot == null) return;
    try {
      await ClaudeSetup.write(_setup.root, slot.rel, _text.text);
    } catch (e) {
      widget.store.showBanner('não consegui salvar ${slot.rel}: $e', sticky: true);
      return;
    }
    _disk = _text.text;
    _loaded = _disk;
    _outside = false;
    _slots = ClaudeSetup.scan(_setup.root);
    widget.store.showBanner('${slot.label} salvo');
    if (mounted) setState(() {});
  }

  /// Volta ao que está no disco, jogando fora o que foi digitado.
  Future<void> _revert() async {
    if (_edited && !await _confirmDiscard()) return;
    await _load();
  }

  Future<void> _add(SetupSection section) async {
    final name = await promptText(
      context,
      title: 'nova ${section.noun}',
      label: switch (section) {
        SetupSection.skills => 'nome (vira /nome)',
        SetupSection.decisions => 'título da decisão',
        _ => 'nome',
      },
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final rel = ClaudeSetup.relFor(section, name, root: _setup.root);
    if (rel == null) {
      widget.store.showBanner('esse nome não sobra nada depois de virar arquivo');
      return;
    }
    if (File(ClaudeSetup.pathOf(_setup.root, rel)).existsSync()) {
      widget.store.showBanner('já existe: $rel');
      await _select(rel);
      return;
    }
    if (_edited && _slot != null && !await _confirmDiscard()) return;
    try {
      await ClaudeSetup.write(
        _setup.root,
        rel,
        ClaudeSetup.template(rel, folderName: _setup.name, title: name.trim()),
      );
    } catch (e) {
      widget.store.showBanner('não consegui criar $rel: $e', sticky: true);
      return;
    }
    _slots = ClaudeSetup.scan(_setup.root);
    _setup.selected = rel;
    widget.store.touch();
    await _load();
    _editor.requestFocus();
  }

  Future<void> _delete() async {
    final slot = _slot;
    if (slot == null || !slot.exists) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Mx.bgSidebar,
        title: Text('apagar ${slot.label}?', style: const TextStyle(fontSize: 15)),
        content: Text(
          slot.section == SetupSection.skills && slot.rel.endsWith('/SKILL.md')
              ? 'a pasta da skill vai junto, com o que mais houver dentro dela.'
              : ClaudeSetup.pathOf(_setup.root, slot.rel),
          style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgFaint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Mx.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('apagar'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    try {
      await ClaudeSetup.remove(_setup.root, slot.rel);
    } catch (e) {
      widget.store.showBanner('não consegui apagar ${slot.rel}: $e', sticky: true);
      return;
    }
    _slots = ClaudeSetup.scan(_setup.root);
    // Um fixo continua na lista e volta a oferecer o modelo; um descoberto
    // sumiu, e a seleção vai com ele.
    if (!slot.fixed) {
      _setup.selected = null;
      widget.store.touch();
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => widget.onFocus?.call(),
      child: MxPanel(
        focused: widget.focused,
        showFocus: widget.showFocus,
        tint: widget.store.tintOf(widget.tab),
        child: Column(
          children: [
            _SetupHeader(
              store: widget.store,
              tab: widget.tab,
              dimmed: widget.showFocus && !widget.focused,
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 232, child: _index()),
                  Container(width: 1, color: Mx.border),
                  Expanded(child: _surface()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A coluna da esquerda: as prateleiras, e em cada uma os arquivos que
  /// existem e os que poderiam existir.
  Widget _index() {
    final selected = _setup.selected;
    return Container(
      color: Mx.bgSidebar,
      child: Scrollbar(
        controller: _list,
        child: ListView(
          controller: _list,
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 16),
          children: [
            for (final section in SetupSection.values) ...[
              _SectionHead(
                section: section,
                onAdd: section.open ? () => _add(section) : null,
              ),
              for (final slot in _slots.where((s) => s.section == section))
                _SlotRow(
                  slot: slot,
                  selected: slot.rel == selected,
                  onTap: () => _select(slot.rel),
                ),
              if (section.open && !_slots.any((s) => s.section == section))
                _EmptyRow(section: section, onTap: () => _add(section)),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _surface() {
    final slot = _slot;
    if (slot == null) return _Welcome(name: _setup.name);
    final zoom = widget.tab.zoom;
    final save = Platform.isMacOS
        ? const SingleActivator(LogicalKeyboardKey.keyS, meta: true)
        : const SingleActivator(LogicalKeyboardKey.keyS, control: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _EditorHead(
          store: widget.store,
          slot: slot,
          root: _setup.root,
          dirty: _dirty,
          edited: _edited,
          outside: _outside,
          onSave: _save,
          onRevert: _revert,
          onDelete: slot.exists ? _delete : null,
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: {save: _save},
            child: TextField(
              controller: _text,
              focusNode: _editor,
              expands: true,
              maxLines: null,
              minLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              style: TextStyle(
                fontFamily: Mx.mono,
                fontSize: 12.5 + zoom,
                height: 1.55,
                color: Mx.fg,
              ),
              cursorColor: Mx.accent,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.fromLTRB(18, 14, 18, 24),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// O cabeçalho: o mesmo desenho dos outros painéis, com os botões que fazem
/// sentido pra uma pasta de configuração.
class _SetupHeader extends StatelessWidget {
  const _SetupHeader({required this.store, required this.tab, required this.dimmed});

  final AppStore store;
  final MxTab tab;
  final bool dimmed;

  Widget _faded(Widget child) => dimmed ? Opacity(opacity: 0.55, child: child) : child;

  @override
  Widget build(BuildContext context) {
    final setup = tab.setup!;
    final index = store.tabs.indexWhere((t) => t.id == tab.id);
    return Container(
      height: 42,
      decoration: paneHeaderBox(store.tintOf(tab)),
      padding: const EdgeInsets.only(left: 12, right: 8),
      child: Row(
        children: [
          Icon(Icons.tune, size: 17, color: Mx.fgDim),
          const SizedBox(width: 9),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  Flexible(
                    child: Text(tab.title, overflow: TextOverflow.ellipsis, style: paneTitleStyle),
                  ),
                  PaneKeyHint(index: index),
                  if (box.maxWidth >= 190) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      flex: 2,
                      child: _faded(
                        Text(
                          setup.root,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: Mx.mono, fontSize: 11, color: Mx.fgFaint),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _faded(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Action(
                  icon: Icons.folder_open_outlined,
                  tooltip: 'mostrar a pasta no Finder',
                  onPressed: () => Notifier.reveal(setup.root),
                ),
                _Action(
                  icon: Icons.edit_outlined,
                  tooltip: 'abrir a pasta no vscode',
                  onPressed: () => store.openInEditor(setup.root),
                ),
                _Action(
                  icon: Icons.close,
                  tooltip: 'fechar esta configuração',
                  // Fechar de verdade, como o leitor: não há processo nem
                  // conversa pra guardar na lateral.
                  onPressed: () => store.closeTab(tab),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// O nome de uma prateleira, e o + de quem aceita arquivo novo.
class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.section, this.onAdd});

  final SetupSection section;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 2, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              section.label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: Mx.fgFaint,
              ),
            ),
          ),
          // O `?` em toda prateleira, o `+` só nas abertas: perguntar o que
          // é uma coisa vale pra todas, criar mais uma não.
          _Help(section: section, size: 12),
          if (onAdd != null)
            IconButton(
              tooltip: 'nova ${section.noun}',
              iconSize: 14,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: onAdd,
              icon: Icon(Icons.add, color: Mx.fgFaint),
            ),
        ],
      ),
    );
  }
}

/// Uma linha da lista: o arquivo, e se ele está lá.
///
/// O que não existe aparece apagado e com o ponto vazio: a linha é uma
/// oferta, não um fato. Clicar nela abre o modelo, e salvar cria.
class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot, required this.selected, required this.onTap});

  final SetupSlot slot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = slot.exists ? Mx.fg : Mx.fgFaint;
    return Material(
      color: selected ? Mx.bgActive : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(
                slot.exists ? Icons.circle : Icons.circle_outlined,
                size: 7,
                color: slot.exists ? (selected ? Mx.accent : Mx.fgDim) : Mx.fgFaint,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  slot.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: Mx.mono,
                    fontSize: 11.5,
                    color: color,
                    fontStyle: slot.exists ? FontStyle.normal : FontStyle.italic,
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

/// A prateleira aberta que ainda não tem nada: a linha é o convite.
class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.section, required this.onTap});

  final SetupSection section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 12, color: Mx.fgFaint),
            const SizedBox(width: 8),
            Text(
              'criar a primeira ${section.noun}…',
              style: TextStyle(fontSize: 11.5, color: Mx.fgFaint),
            ),
          ],
        ),
      ),
    );
  }
}

/// Em cima do editor: o caminho, o estado do arquivo, e a frase que diz pra
/// que ele serve.
class _EditorHead extends StatelessWidget {
  const _EditorHead({
    required this.store,
    required this.slot,
    required this.root,
    required this.dirty,
    required this.edited,
    required this.outside,
    required this.onSave,
    required this.onRevert,
    required this.onDelete,
  });

  final AppStore store;
  final SetupSlot slot;
  final String root;
  final bool dirty;

  /// Você digitou algo desde que o arquivo entrou no editor. Difere de
  /// [dirty] num arquivo que não existe: o modelo dele difere do disco sem
  /// você ter feito nada.
  final bool edited;

  final bool outside;
  final VoidCallback onSave;
  final VoidCallback onRevert;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final saveKey = Platform.isMacOS ? '⌘S' : 'ctrl+S';
    final (String state, Color stateColor) = outside
        ? ('mudou no disco enquanto você editava', Mx.yellow)
        : !slot.exists
        ? ('não existe ainda — salvar cria', Mx.fgFaint)
        : dirty
        ? ('não salvo', Mx.yellow)
        : ('salvo', Mx.fgFaint);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 10, 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Mx.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: slot.rel,
                        style: TextStyle(fontFamily: Mx.mono, fontSize: 12, color: Mx.fg),
                      ),
                      TextSpan(
                        text: '  ·  $state',
                        style: TextStyle(fontSize: 11, color: stateColor),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _Help(section: slot.section),
              const SizedBox(width: 2),
              _Action(
                icon: Icons.save_outlined,
                tooltip: 'salvar  $saveKey',
                on: dirty || !slot.exists,
                onPressed: dirty || !slot.exists ? onSave : null,
              ),
              _Action(
                icon: Icons.history,
                tooltip: 'voltar ao que está no disco',
                onPressed: edited || outside ? onRevert : null,
              ),
              if (slot.exists)
                _Action(
                  icon: Icons.edit_outlined,
                  tooltip: 'abrir no vscode',
                  onPressed: () => store.openInEditor(ClaudeSetup.pathOf(root, slot.rel)),
                ),
              _Action(
                icon: Icons.delete_outline,
                tooltip: 'apagar o arquivo',
                onPressed: onDelete,
                danger: true,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            slot.about,
            style: TextStyle(fontSize: 11.5, height: 1.4, color: Mx.fgDim),
          ),
        ],
      ),
    );
  }
}

/// O que se vê com nada escolhido: o que cada prateleira é, pra quem chegou
/// aqui pela primeira vez -- que é quando a pergunta é feita.
class _Welcome extends StatelessWidget {
  const _Welcome({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 24, 26, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'o que o claude lê em $name',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Mx.fg),
              ),
              const SizedBox(height: 6),
              Text(
                'escolha um arquivo à esquerda pra editar. o que está apagado ainda não '
                'existe: abrir mostra um modelo, e salvar cria. o ? de cada prateleira '
                'explica o que ela é, com exemplo.',
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Mx.fgDim),
              ),
              const SizedBox(height: 22),
              for (final section in SetupSection.values) ...[
                Row(
                  children: [
                    Text(
                      section.label,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Mx.fg),
                    ),
                    const SizedBox(width: 4),
                    _Help(section: section),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  section.about,
                  style: TextStyle(fontSize: 12, height: 1.5, color: Mx.fgDim),
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A explicação de uma prateleira, pra quem clicou no `?`.
///
/// Um diálogo e não um tooltip: o texto tem título, lista e exemplo, e um
/// tooltip some quando o ponteiro anda. É o mesmo markdown dos painéis de
/// leitura, com a mesma folha de estilo (ver [MxMarkdown]) -- um exemplo de
/// `SKILL.md` aqui tem que parecer um bloco de código como lá.
Future<void> explainSection(BuildContext context, SetupSection section) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Mx.bgSidebar,
      title: Row(
        children: [
          Icon(Icons.help_outline, size: 16, color: Mx.fgDim),
          const SizedBox(width: 8),
          Text(section.label, style: const TextStyle(fontSize: 15)),
        ],
      ),
      content: SizedBox(
        width: 600,
        // O texto do agente é o mais longo e passa de uma tela: rola dentro
        // do diálogo, e o diálogo não cresce além da janela.
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: SingleChildScrollView(
            child: MxMarkdown(data: section.help, fontSize: MxMarkdown.baseSize - 0.5),
          ),
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('entendi')),
      ],
    ),
  );
}

/// O `?` que abre [explainSection]. Pequeno e apagado de propósito: é uma
/// oferta de ajuda, não um botão da tarefa.
class _Help extends StatelessWidget {
  const _Help({required this.section, this.size = 13});

  final SetupSection section;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'o que é ${section.label}?',
      iconSize: size,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 22, height: 22),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: () => explainSection(context, section),
      icon: Icon(Icons.help_outline, color: Mx.fgFaint),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Aceso: o botão está dizendo que tem o que fazer.
  final bool on;

  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? Mx.fgFaint.withValues(alpha: 0.5)
        : danger
        ? Mx.red
        : on
        ? Mx.accent
        : Mx.fgDim;
    return IconButton(
      tooltip: tooltip,
      iconSize: 15,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      onPressed: onPressed,
      icon: Icon(icon, color: color),
    );
  }
}
