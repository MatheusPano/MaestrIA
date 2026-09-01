import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../theme.dart';
import 'agents.dart';
import 'editor.dart';
import 'git.dart';
import 'hooks.dart';
import 'layout.dart';
import 'notify.dart';
import 'pty.dart';
import 'shell.dart';
import 'shortcuts.dart';

enum TabKind { shell, claude }

/// One panel. Owns its pty and its hook-derived state.
class MxTab {
  MxTab({
    required this.id,
    required this.folder,
    required this.kind,
    required this.cwd,
    required this.branch,
    this.customLabel,
  });

  final String id;

  /// Held by reference, not by path, so renaming a folder renames its panels.
  final Folder folder;
  final TabKind kind;
  final String cwd;
  String branch;
  String? customLabel;

  final TermSession term = TermSession();
  final HookState hooks = HookState();

  /// The project inside the folder this panel is part of, if any. Null is a
  /// panel that is just a panel in a folder -- the shape everything had before
  /// projects existed, and still the right one for a one-off session.
  String? projectId;

  /// The step waiting out [AppStore.followUpDelay]. Held so that closing the
  /// panel -- or the window -- takes it with it, instead of letting it fire
  /// into a session nobody is watching any more.
  Timer? pendingFollowUp;

  /// What happens the next time this session goes quiet, in order.
  ///
  /// Deliberately not saved with the layout. A queue is armed for a session
  /// that is running *now*; a restored panel comes back with `--resume` and is
  /// idle from its first breath, so a persisted queue would fire the whole
  /// thing into a session that had not been asked anything.
  final List<FollowUp> followUps = [];

  /// Whether the fork rows under this panel are folded away. Começa fechada:
  /// uma frota aberta empurra os painéis de baixo pra fora do rail toda vez
  /// que um turno resolve delegar, e o que a sessão está fazendo o subtítulo
  /// dela já diz. Quem quiser ver os forks abre a linha.
  ///
  /// Not saved: the forks belong to the turn that spawned them, so a fold
  /// state that outlived them would come back pointing at nothing.
  bool fleetCollapsed = true;

  /// Filled in from `claude agents --json` once the session registers itself.
  String? sessionId;

  /// O `--name` com que esta sessão subiu: como o `claude agents` a lista e o
  /// único endereço que outro agente tem pra ela -- `ListAgents` e
  /// `SendMessage` falam nomes, nunca ids de sessão. Anotado no launch e
  /// atualizado pelo que o CLI responde, que é a resposta que vale.
  ///
  /// Não é o [title] e de propósito não anda junto com ele: renomear o painel
  /// renomeia o painel, enquanto o processo lá fora continua atendendo pelo
  /// nome com que foi iniciado.
  String? agentName;
  int dirty = 0;
  final DateTime startedAt = DateTime.now();

  /// Marked by hand: this session did its job.
  ///
  /// The one piece of a panel's state that nothing derives, because nothing
  /// can. A session that stops is [ClaudeStatus.idle], which says the turn
  /// ended -- not that the answer was any good. Only the person who read it
  /// knows that, so this is a judgement the app is told, never one it infers.
  ///
  /// It is not "closed" either: a panel marked done keeps its scrollback and
  /// its session id, so the answer is still on screen and the conversation is
  /// still resumable. What it stops being is *pending*.
  bool done = false;

  /// The panel title, in the order of what a human would actually recognise:
  /// what you named it, then the branch's task id, then the folder.
  String get folderRoot => folder.root;

  String get title {
    if (customLabel != null && customLabel!.isNotEmpty) return customLabel!;
    // A loose panel has no folder to be named after. What it does have is the
    // folder it was pointed at -- and `~` when that is only home.
    if (folder.isLoose) return cwd == folder.root ? '~' : cwd.split('/').last;
    // In the main checkout the branch is almost always the trunk, and four
    // panels called "master" name nothing. There, the folder is the name.
    if (cwd == folder.root) return folder.name;
    if (branch.isNotEmpty && branch != '(detached)') {
      final m = RegExp(r'([A-Za-z]+[#-]?\d+)').firstMatch(branch);
      if (m != null) return m.group(1)!;
      return branch.split('/').last;
    }
    return cwd.split('/').last;
  }

  String get subtitle {
    if (exited) return 'processo saiu (${term.exitCode ?? '?'})';
    if (kind == TabKind.shell) return 'shell';
    return hooks.subtitle;
  }

  bool get exited => term.exited;
  ClaudeStatus get status =>
      kind == TabKind.shell ? (exited ? ClaudeStatus.ended : ClaudeStatus.unknown) : hooks.status;

  /// What it takes to bring this panel back next time the app opens.
  Map<String, dynamic> toJson() => {
    'folderRoot': folder.root,
    if (folder.isLoose) 'loose': true,
    if (projectId != null) 'projectId': projectId,
    'kind': kind.name,
    'cwd': cwd,
    if (customLabel != null) 'label': customLabel,
    // The session id is the whole point: a restored panel resumes the
    // conversation instead of starting a stranger in the same folder.
    if (kind == TabKind.claude && (sessionId ?? hooks.sessionId) != null)
      'sessionId': sessionId ?? hooks.sessionId,
    // Unlike the queue, which is armed for a session running *now*, what the
    // work produced outlives the session that produced it: the six files are
    // still the six files tomorrow morning.
    if (hooks.touched.isNotEmpty) 'touched': hooks.touched,
    // Worth the trip through the config: it is the one thing about a panel
    // that only you knew, and a restart that forgot it would be asking you
    // to read four sessions again to find out which three were settled.
    if (done) 'done': true,
  };
}

/// Em que prateleira do menu de filtros uma opção fica.
///
/// Existe porque as duas se combinam de formas diferentes: dentro de um grupo
/// as opções somam ("claude *ou* shell"), entre grupos elas cortam ("claude
/// *e* esperando você"). Sem isso, marcar duas coisas de grupos diferentes
/// devolvia lista vazia e parecia bug.
enum MxFilterGroup {
  kind('tipo'),
  state('estado');

  const MxFilterGroup(this.label);
  final String label;
}

/// Uma opção do menu de filtros da lateral, fora do escopo (pastas e
/// projetos, que são a lista do próprio usuário) e do texto digitado.
enum MxFilter {
  claude('sessões do claude', MxFilterGroup.kind),
  shell('terminais', MxFilterGroup.kind),
  waiting('esperando você', MxFilterGroup.state),
  working('rodando', MxFilterGroup.state),
  parked('paradas', MxFilterGroup.state),
  finished('concluídas', MxFilterGroup.state);

  const MxFilter(this.label, this.group);
  final String label;
  final MxFilterGroup group;

  bool matches(MxTab t) => switch (this) {
    MxFilter.claude => t.kind == TabKind.claude,
    MxFilter.shell => t.kind == TabKind.shell,
    // Concluída sai de "esperando você" e de "paradas" de propósito: o tique é
    // você dizendo que essa já foi, e uma sessão guardada não é uma pendência.
    MxFilter.waiting => !t.done && t.status.needsHuman,
    MxFilter.working => t.status == ClaudeStatus.working || t.status == ClaudeStatus.tool,
    MxFilter.parked =>
      !t.done &&
          (t.status == ClaudeStatus.idle ||
              t.status == ClaudeStatus.ready ||
              t.status == ClaudeStatus.ended ||
              t.exited),
    MxFilter.finished => t.done,
  };
}

class AppStore extends ChangeNotifier {
  final HookServer hooks = HookServer();
  final AgentsWatcher agents = AgentsWatcher();
  final Notifier notifier = Notifier();

  final List<Folder> folders = [];

  /// The named jobs inside those folders. Flat, keyed back to a folder by
  /// [Project.folderRoot] -- the sidebar is what nests them.
  final List<Project> projects = [];

  /// Where panels that belong to no repo live. Not in [folders]: it is never
  /// saved, never git-refreshed, and never removable -- it is a place to put
  /// things, not a thing the user added.
  final Folder loose = Folder.loose(Platform.environment['HOME'] ?? '/');

  final List<MxTab> tabs = [];
  final Map<String, List<WorktreeInfo>> worktrees = {};

  /// A árvore de painéis, ou null com a tela limpa. As regras de corte,
  /// colapso e proporção estão em `layout.dart`; o que fica aqui é o foco e os
  /// gestos que a lateral e os painéis disparam.
  PaneNode? panes;

  /// Qual painel o teclado está escutando, pelo id da sessão que ele mostra.
  String? focusedPaneId;

  String? banner;

  /// How wide the sidebar is, in logical pixels. Dragged by the gutter between
  /// it and the panes, and remembered — a width you set once is a width you
  /// set once.
  static const double minSidebar = 248;
  static const double maxSidebar = 680;
  static const double defaultSidebar = 352;
  double sidebarWidth = defaultSidebar;

  /// The chosen palette. Lives here because it is remembered like everything
  /// else the window keeps; [Mx.current] is what the widgets actually read.
  MxPalette get theme => Mx.palette;

  /// As teclas e o que elas fazem. Guardado aqui pelo mesmo motivo do tema:
  /// é uma escolha que a janela lembra. Quem lê é `ui/keys.dart`.
  final MxKeymap keymap = MxKeymap();

  int _seq = 0;
  bool _restoring = false;
  Timer? _saveDebounce;

  /// Alerts already fired, keyed per session, so a state that stays put does
  /// not notify every two seconds.
  final Set<String> _alerted = {};

  MxTab? _byId(String? id) => id == null ? null : tabs.firstWhereOrNull((t) => t.id == id);

  /// A sessão de um id. A árvore de painéis guarda ids, então quem a desenha
  /// precisa desta volta.
  MxTab? tabById(String? id) => _byId(id);

  /// As sessões na tela, na ordem em que aparecem nela.
  List<MxTab> get openPanes => [
    for (final id in Panes.order(panes))
      if (_byId(id) case final tab?) tab,
  ];

  int get paneCount => Panes.count(panes);

  bool isOpen(MxTab tab) => Panes.has(panes, tab.id);

  /// Cai no primeiro painel quando o foco aponta pra uma sessão que já saiu da
  /// tela: sempre há um painel em foco enquanto houver painel.
  MxTab? get focusedTab => _byId(focusedPaneId) ?? _byId(Panes.order(panes).firstOrNull);

  Future<void> init() async {
    await hooks.start();
    hooks.events.listen(applyHook);
    agents.updates.listen(applyAgents);
    await _loadConfig();
    agents.start();
    Timer.periodic(const Duration(seconds: 1), (_) {
      // Only the elapsed-seconds readouts need this cadence.
      if (tabs.any((t) => t.status == ClaudeStatus.tool)) notifyListeners();
    });
    Timer.periodic(const Duration(seconds: 10), (_) => refreshGit());
    notifyListeners();
  }

  // --- persistence --------------------------------------------------------

  File get _configFile => File('${Platform.environment['HOME']}/.maestria/config.json');

  Future<void> _loadConfig() async {
    try {
      if (!_configFile.existsSync()) return;
      final j = jsonDecode(await _configFile.readAsString()) as Map<String, dynamic>;
      // Before projects existed, folders were what `projects` meant. Reading
      // the old key keeps a config written by yesterday's build from opening
      // as an empty sidebar.
      final legacy = j['folders'] == null;
      for (final p in ((legacy ? j['projects'] : j['folders']) as List? ?? const [])) {
        folders.add(Folder.fromJson(p as Map<String, dynamic>));
      }
      if (!legacy) {
        for (final p in (j['projects'] as List? ?? const [])) {
          projects.add(Project.fromJson(p as Map<String, dynamic>));
        }
      }
      final w = (j['sidebarWidth'] as num?)?.toDouble();
      if (w != null) sidebarWidth = w.clamp(minSidebar, maxSidebar);
      Mx.applyId(j['theme'] as String?);
      keymap.load(j['shortcuts']);
      await refreshGit();
      await _restoreLayout(j['layout'] as Map<String, dynamic>?);
    } catch (_) {}
  }

  /// Bring back the panels from last time, processes and all.
  ///
  /// A layout that reopens empty is not a layout. Claude panels come back with
  /// `--resume`, so the panel you left mid-task is the panel you get.
  Future<void> _restoreLayout(Map<String, dynamic>? layout) async {
    if (layout == null) return;
    final saved = (layout['panes'] as List? ?? const []).whereType<Map<String, dynamic>>();
    if (saved.isEmpty) return;

    _restoring = true;
    final restored = <MxTab>[];
    for (final pane in saved) {
      final root = (pane['folderRoot'] ?? pane['projectRoot']) as String?;
      final folder = pane['loose'] == true
          ? loose
          : folders.firstWhereOrNull((f) => f.root == root);
      final cwd = pane['cwd'] as String?;
      if (folder == null || cwd == null || !Directory(cwd).existsSync()) continue;
      final label = pane['label'] as String?;
      final project = projectById(pane['projectId'] as String?);
      final tab = pane['kind'] == 'claude'
          ? openClaude(
              folder,
              cwd: cwd,
              label: label,
              project: project,
              resumeId: pane['sessionId'] as String?,
            )
          : openShell(folder, cwd: cwd, project: project);
      if (label != null) tab.customLabel = label;
      tab.hooks.touched.addAll((pane['touched'] as List? ?? const []).whereType<String>());
      tab.done = pane['done'] == true;
      restored.add(tab);
    }
    _restoring = false;

    if (restored.isEmpty) return;
    // -1 é o que o `indexWhere` grava quando a última coisa que você fez foi
    // tirar tudo do painel: volta com as sessões vivas na lateral e a tela
    // limpa, que é como você deixou.
    MxTab? at(int? i) => i != null && i >= 0 && i < restored.length ? restored[i] : null;
    if (layout['tree'] case final tree?) {
      panes = Panes.fromJson(tree, (i) => at(i)?.id);
    } else if (at((layout['active'] as int?) ?? 0) case final left?) {
      // Um config escrito antes da grade existir: dois slots, esquerda e
      // direita. Vira a fileira de dois que ele sempre foi.
      final right = at(layout['split'] as int?);
      panes = right == null
          ? PaneLeaf(left.id)
          : PaneSplit(PaneAxis.row, [PaneLeaf(left.id), PaneLeaf(right.id)], [0.5, 0.5]);
    }
    focusedPaneId = at(layout['focused'] as int?)?.id ?? Panes.order(panes).firstOrNull;
    banner = '${restored.length} painéis restaurados da última sessão';
    notifyListeners();
  }

  void _save() {
    if (_restoring) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _writeConfig);
  }

  Future<void> _writeConfig() async {
    try {
      await _configFile.parent.create(recursive: true);
      final open = tabs.where((t) => !t.exited).toList();
      final tree = Panes.toJson(panes, (id) => open.indexWhere((t) => t.id == id));
      await _configFile.writeAsString(
        jsonEncode({
          'folders': folders.map((f) => f.toJson()).toList(),
          'projects': projects.map((p) => p.toJson()).toList(),
          'sidebarWidth': sidebarWidth,
          'theme': Mx.palette.id,
          if (keymap.toJson() case final binds when binds.isNotEmpty) 'shortcuts': binds,
          'layout': {
            'panes': open.map((t) => t.toJson()).toList(),
            if (tree != null) 'tree': tree,
            'focused': open.indexWhere((t) => t.id == focusedPaneId),
          },
        }),
      );
    } catch (_) {}
  }

  /// Repaints the window in [palette] and remembers the choice.
  void setTheme(MxPalette palette) {
    if (palette.id == Mx.palette.id) return;
    Mx.apply(palette);
    _save();
    notifyListeners();
  }

  /// Põe [chord] em [action] e avisa de quem ela foi tirada — um atalho que
  /// muda de dono em silêncio é uma tecla que um dia simplesmente para de
  /// funcionar, sem nada na tela ligando uma coisa à outra.
  void bindShortcut(MxAction action, MxChord chord, {MxChord? replacing}) {
    final stolen = keymap.bind(action, chord, replacing: replacing);
    if (stolen != null) showBanner('${chord.label} saiu de "${stolen.label}"');
    _save();
    notifyListeners();
  }

  void unbindShortcut(MxAction action, MxChord chord) {
    keymap.unbind(action, chord);
    _save();
    notifyListeners();
  }

  void resetShortcuts([MxAction? action]) {
    action == null ? keymap.reset() : keymap.resetAction(action);
    _save();
    notifyListeners();
  }

  /// Called on every drag frame, so it bails when the clamp swallowed the
  /// delta — otherwise dragging past the end keeps repainting for nothing.
  void setSidebarWidth(double width) {
    final w = width.clamp(minSidebar, maxSidebar);
    if (w == sidebarWidth) return;
    sidebarWidth = w;
    _save();
    notifyListeners();
  }

  // --- folders -----------------------------------------------------------

  Future<Folder?> addFolder(String path) async {
    final root = await Git.mainRoot(path);
    final resolved = root ?? path;
    final existing = folders.firstWhereOrNull((p) => p.root == resolved);
    if (existing != null) return existing;
    if (!Directory(resolved).existsSync()) {
      showBanner('pasta não encontrada: $path');
      return null;
    }
    final folder = Folder(root: resolved, name: resolved.split('/').last);
    folders.add(folder);
    _save();
    await refreshGit();
    notifyListeners();
    return folder;
  }

  void renameFolder(Folder p, String name) {
    p.name = name;
    _save();
    notifyListeners();
  }

  void toggleCollapsed(Folder p) {
    p.collapsed = !p.collapsed;
    _save();
    notifyListeners();
  }

  void toggleWorktrees(Folder p) {
    p.worktreesCollapsed = !p.worktreesCollapsed;
    _save();
    notifyListeners();
  }

  Future<void> removeFolder(Folder p) async {
    folders.remove(p);
    projects.removeWhere((pr) => pr.folderRoot == p.root);
    for (final t in tabs.where((t) => t.folderRoot == p.root).toList()) {
      closeTab(t);
    }
    _save();
    notifyListeners();
  }

  Future<void> refreshGit() async {
    for (final p in folders) {
      final list = await Git.worktrees(p.root);
      // A call that could not answer keeps the last answer. Writing an empty
      // list here on a lost `git` call is what made the sidebar fold a
      // folder's worktrees away and unfold them ten seconds later, with
      // everything below jumping both times.
      if (list == null) continue;
      worktrees[p.root] = list;
      // `worktree list` fails outside a repo, so an empty list is the answer
      // to "is this even a repo" -- and its first entry is the main checkout,
      // which is the branch the folder itself is sitting on.
      p.isRepo = list.isNotEmpty;
      p.branch = list.firstWhereOrNull((w) => w.isMain)?.branch ?? '';
    }
    for (final t in tabs) {
      t.dirty = await Git.dirtyCount(t.cwd) ?? t.dirty;
      if (t.branch.isEmpty) t.branch = await Git.branchOf(t.cwd);
    }
    notifyListeners();
  }

  /// Where a new panel lands: the folder you are looking at, and the loose
  /// tray when you are looking at nothing at all.
  Folder get focusedFolder {
    final tab = focusedTab;
    if (tab != null) {
      if (tab.folder.isLoose) return loose;
      final p = folders.firstWhereOrNull((p) => p.root == tab.folderRoot);
      if (p != null) return p;
    }
    return folders.firstOrNull ?? loose;
  }

  // --- busca --------------------------------------------------------------

  /// O que está escrito no campo de busca da lateral.
  ///
  /// Nada disto vai pro config, e é de propósito: uma busca é sobre agora. Um
  /// filtro que sobrevivesse ao restart abriria o app escondendo metade das
  /// sessões sem ninguém ter pedido.
  String query = '';

  /// As pastas e os projetos marcados no menu de filtros, pela identidade que
  /// sobrevive a um rename: o root e o id.
  final Set<String> filterRoots = {};
  final Set<String> filterProjects = {};
  final Set<MxFilter> filterFlags = {};

  /// Os termos de [query], separados: "google perm" acha "permissão do google"
  /// sem exigir a ordem. Recalculado ao digitar, não a cada linha desenhada.
  List<String> _terms = [];

  bool get filtering =>
      _terms.isNotEmpty ||
      filterRoots.isNotEmpty ||
      filterProjects.isNotEmpty ||
      filterFlags.isNotEmpty;

  /// Quantas opções estão marcadas, pro ponto no botão de filtro.
  int get activeFilters => filterRoots.length + filterProjects.length + filterFlags.length;

  void setQuery(String q) {
    if (q == query) return;
    query = q;
    _terms = q.toLowerCase().split(' ').where((t) => t.isNotEmpty).toList();
    notifyListeners();
  }

  void toggleFilter(MxFilter f) {
    filterFlags.contains(f) ? filterFlags.remove(f) : filterFlags.add(f);
    notifyListeners();
  }

  void toggleFilterFolder(Folder f) {
    filterRoots.contains(f.root) ? filterRoots.remove(f.root) : filterRoots.add(f.root);
    notifyListeners();
  }

  void toggleFilterProject(Project p) {
    filterProjects.contains(p.id) ? filterProjects.remove(p.id) : filterProjects.add(p.id);
    notifyListeners();
  }

  /// Volta a lateral a mostrar tudo. Um caminho só, chamado pelo x do campo,
  /// pelo "limpar" do menu, pelo Esc e pela tela de "nada encontrado" — quatro
  /// saídas que precisam deixar exatamente o mesmo estado.
  void clearSearch() {
    if (!filtering && query.isEmpty) return;
    query = '';
    _terms = [];
    filterRoots.clear();
    filterProjects.clear();
    filterFlags.clear();
    notifyListeners();
  }

  /// Tudo em que a busca procura, numa linha. O que *não* está aqui é o
  /// subtítulo: ele muda a cada turno da sessão, e uma lista de resultados que
  /// se remonta sozinha enquanto o agente fala é uma lista que não dá pra usar.
  String _haystack(MxTab t) => [
    t.title,
    t.customLabel ?? '',
    t.folder.name,
    projectOf(t)?.name ?? '',
    t.branch,
    t.cwd,
    t.agentName ?? '',
    // Pra "shell" e "claude" acharem por tipo sem passar pelo menu.
    t.kind.name,
  ].join(' ').toLowerCase();

  /// Esta sessão passa pela busca e pelos filtros de agora?
  bool matches(MxTab t) {
    if (_terms.isNotEmpty) {
      final hay = _haystack(t);
      if (!_terms.every(hay.contains)) return false;
    }
    // Pasta e projeto são o mesmo grupo — o "onde" — e somam entre si: marcar
    // um repo e um projeto de outro repo mostra os dois, não nada.
    if (filterRoots.isNotEmpty || filterProjects.isNotEmpty) {
      final scoped =
          filterRoots.contains(t.folderRoot) ||
          (t.projectId != null && filterProjects.contains(t.projectId));
      if (!scoped) return false;
    }
    for (final group in MxFilterGroup.values) {
      final picked = filterFlags.where((f) => f.group == group);
      if (picked.isNotEmpty && !picked.any((f) => f.matches(t))) return false;
    }
    return true;
  }

  /// A lista que uma parte da lateral desenha: tudo, ou só os achados.
  List<MxTab> visible(Iterable<MxTab> of) => (filtering ? of.where(matches) : of).toList();

  /// Se este grupo tem alguma coisa a mostrar. Um grupo sem achado nenhum sai
  /// da lateral inteiro enquanto a busca durar — um cabeçalho vazio é uma
  /// linha dizendo "não é aqui" ocupando o lugar de uma que é.
  bool hasHits(Folder f) => tabsOf(f).any(matches);

  List<MxTab> get hits => tabs.where(matches).toList();

  // --- projects -----------------------------------------------------------

  List<Project> projectsOf(Folder f) => projects.where((p) => p.folderRoot == f.root).toList();

  Project? projectById(String? id) =>
      id == null ? null : projects.firstWhereOrNull((p) => p.id == id);

  Project? projectOf(MxTab tab) => projectById(tab.projectId);

  /// The project a new panel joins when the caller did not name one: whichever
  /// the panel you are looking at is in. Opening a third session while you are
  /// inside "permissão do google" means a third session on that job.
  Project? get focusedProject {
    final tab = focusedTab;
    return tab == null ? null : projectOf(tab);
  }

  Project addProject(Folder f, String name, {String brief = ''}) {
    final project = Project(
      // Not the tab counter: this one outlives the window, and `tab3` would
      // name a different project every time the app restarts.
      id: 'pj${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      folderRoot: f.root,
      name: name,
      brief: brief,
    );
    projects.add(project);
    _save();
    notifyListeners();
    return project;
  }

  void editProject(Project project, {String? name, String? brief}) {
    if (name != null && name.trim().isNotEmpty) project.name = name.trim();
    if (brief != null) project.brief = brief;
    _save();
    notifyListeners();
  }

  /// Fold the panel's subagents away, the way a folder folds its panels.
  void toggleFleet(MxTab tab) {
    tab.fleetCollapsed = !tab.fleetCollapsed;
    notifyListeners();
  }

  void toggleProjectCollapsed(Project project) {
    project.collapsed = !project.collapsed;
    _save();
    notifyListeners();
  }

  /// Finish a project: the job is done, so its sessions are over too.
  ///
  /// The one difference from [removeProject] is the only one that matters --
  /// there the panels stay open because the work goes on without the label;
  /// here they close, because saying a project is done and leaving four
  /// sessions of it running would be saying two different things at once.
  /// Nothing is archived: what the job leaves behind is in the repo, and a
  /// briefing worth keeping is a paragraph the caller copies out first.
  ///
  /// Returns how many panels went with it, so the caller can say so.
  int completeProject(Project project) {
    final closing = tabsIn(project);
    for (final t in closing) {
      closeTab(t);
    }
    projects.remove(project);
    _save();
    notifyListeners();
    return closing.length;
  }

  /// Dissolve a project. Its panels are set loose in the folder, not closed --
  /// dropping the label you put on a job is not deciding the job is over.
  void removeProject(Project project) {
    projects.remove(project);
    for (final t in tabs.where((t) => t.projectId == project.id)) {
      t.projectId = null;
    }
    _save();
    notifyListeners();
  }

  /// Move [tab] into [project], or out of every project when it is null.
  ///
  /// A project belongs to one folder, so a panel running somewhere else
  /// cannot join it: the brief would be describing a checkout that session
  /// cannot see.
  void assign(MxTab tab, Project? project) {
    if (project != null && project.folderRoot != tab.folderRoot) return;
    if (tab.projectId == project?.id) return;
    tab.projectId = project?.id;
    _save();
    notifyListeners();
  }

  List<MxTab> tabsIn(Project project) => tabs.where((t) => t.projectId == project.id).toList();

  /// A session marked done is counted nowhere: the mark exists to stop a
  /// finished panel from spending the badge that means "somebody go look".
  int needingHumanIn(Project project) =>
      tabsIn(project).where((t) => !t.done && t.status.needsHuman).length;

  // --- tabs ---------------------------------------------------------------

  MxTab openShell(Folder f, {String? cwd, String? command, Project? project}) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: f,
      kind: TabKind.shell,
      cwd: cwd ?? f.root,
      branch: '',
    );
    if (project != null && project.folderRoot == f.root) tab.projectId = project.id;
    _register(tab);
    if (command == null) {
      tab.term.startShell(tab.cwd);
    } else {
      tab.term.startCommand(command, tab.cwd);
    }
    return tab;
  }

  /// Launch `claude` in [cwd], named, with our hook listeners injected.
  MxTab openClaude(
    Folder f, {
    required String cwd,
    String? label,
    String? resumeId,
    Project? project,
    String? prompt,
  }) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: f,
      kind: TabKind.claude,
      cwd: cwd,
      branch: '',
      customLabel: label,
    );
    tab.sessionId = resumeId;
    if (project != null && project.folderRoot == f.root) tab.projectId = project.id;
    _register(tab);

    final name = (label == null || label.isEmpty) ? tab.cwd.split('/').last : label;
    tab.agentName = name;
    // The project's standing context, when the panel is in one. In the system
    // prompt rather than as a first message: it has to still be true on turn
    // forty, and a first message scrolls out of the window long before that.
    final joined = projectOf(tab);
    final brief = joined?.brief.trim() ?? '';
    final opening = prompt?.trim() ?? '';
    final parts = [
      'claude',
      '--name ${Sh.q(name)}',
      '--settings ${Sh.q(hooks.settingsFor(tab.id))}',
      if (brief.isNotEmpty) '--append-system-prompt ${Sh.q(brief)}',
      if (resumeId != null) '--resume ${Sh.q(resumeId)}',
      // Positional, so it comes last: `claude [flags] '<prompt>'` opens the
      // REPL with that already sent. Typing it into the pty instead would be
      // racing the TUI for its own prompt.
      if (opening.isNotEmpty) Sh.q(opening),
    ];
    tab.term.startCommand(
      parts.join(' '),
      cwd,
      display:
          'claude --name ${Sh.q(name)} '
          '--settings <hooks :${hooks.port}>'
          '${brief.isEmpty ? '' : ' --append-system-prompt <briefing de ${joined!.name}>'}'
          '${resumeId == null ? '' : ' --resume …'}'
          '${opening.isEmpty ? '' : ' <prompt inicial>'}',
    );
    // Nothing reports the prompt being ready -- see `HookState.settle` -- so
    // the panel gives the launch a beat and then says so itself. A session
    // that spoke first (it can only be a prompt you typed) keeps its state.
    Timer(const Duration(seconds: 3), () {
      if (!tabs.contains(tab) || tab.exited) return;
      if (tab.hooks.settle()) notifyListeners();
    });

    Git.branchOf(cwd).then((b) {
      tab.branch = b;
      notifyListeners();
    });
    return tab;
  }

  /// The manual worktree dance, as one button.
  Future<MxTab?> newTask(
    Folder p, {
    required String taskId,
    required String branchPattern,
    required String dirPattern,
    String? baseRef,
    String? setupCommand,
    Project? project,
  }) async {
    final base = baseRef ?? await Git.defaultRemoteRef(p.root) ?? 'origin/master';
    final branch = branchPattern.replaceAll('{id}', taskId);
    final dir = dirPattern.replaceAll('{id}', taskId).replaceAll('#', '-');

    final outcome = await Git.addWorktree(
      root: p.root,
      dirName: dir,
      branch: branch,
      baseRef: base,
    );
    showBanner(outcome.message);
    if (!outcome.ok) return null;

    if (setupCommand != null && setupCommand.trim().isNotEmpty) {
      final shell = openShell(p, cwd: outcome.path, command: setupCommand.trim(), project: project);
      shell.customLabel = '$taskId setup';
    }

    await refreshGit();
    return openClaude(p, cwd: outcome.path, label: taskId, project: project);
  }

  // --- worktrees ----------------------------------------------------------

  /// The panel already running in [path], if any. A worktree with a live
  /// session is one you go back to, not one you open twice.
  MxTab? tabAt(String path) => tabs.firstWhereOrNull((t) => t.cwd == path && !t.exited);

  Future<void> openInEditor(String path) async {
    if (!Directory(path).existsSync()) {
      showBanner('essa pasta não existe mais: $path');
      return;
    }
    final ok = await Editor.open(path);
    showBanner(
      ok
          ? 'aberto no vscode: ${path.split('/').last}'
          : 'não achei o vscode — nem o `code` no PATH, nem o app',
    );
  }

  /// Delete a worktree, once its own panels are out of the way.
  ///
  /// Removing the folder under a running session leaves that pty pointing at
  /// nothing, so the panels come first -- and closing someone's session for
  /// them is not this button's call to make.
  Future<void> removeWorktree(
    Folder p,
    WorktreeInfo w, {
    bool force = false,
    bool deleteBranch = false,
  }) async {
    if (tabAt(w.path) != null) {
      showBanner('feche o painel que está nessa worktree antes de excluí-la');
      return;
    }
    final outcome = await Git.removeWorktree(
      root: p.root,
      worktree: w,
      force: force,
      deleteBranch: deleteBranch,
    );
    showBanner(outcome.message);
    await refreshGit();
  }

  Future<void> pruneWorktrees(Folder p) async {
    final outcome = await Git.prune(p.root);
    showBanner(outcome.message);
    await refreshGit();
  }

  void _register(MxTab tab) {
    tabs.add(tab);
    // A new panel lands in whichever pane you were looking at.
    _place(tab);
    tab.term.onExit = () {
      // Dying in the first seconds is not the same as being closed: it means
      // the launch itself failed, and the reason is sitting in that panel's
      // own buffer.
      final alive = DateTime.now().difference(tab.startedAt);
      if (tab.kind == TabKind.claude && alive.inSeconds < 5) {
        banner =
            '${tab.title}: o claude saiu na largada '
            '(código ${tab.term.exitCode ?? '?'}) — abra o painel pra ver o motivo';
      }
      _save();
      notifyListeners();
    };
    _save();
    notifyListeners();
  }

  void select(MxTab tab) {
    _place(tab);
    _save();
    notifyListeners();
  }

  /// Põe [tab] na tela, sem salvar nem repintar -- o miolo que [select] e
  /// [_register] embrulham cada um do seu jeito.
  ///
  /// Um painel é um lugar, não uma sessão: escolher outra sessão na lateral
  /// troca o que está no lugar em foco em vez de abrir mais um. Abrir lugar é
  /// arrastar -- é o único gesto que divide a tela, e é assim de propósito:
  /// clicar numa lista de vinte sessões não pode ir picando a janela.
  void _place(MxTab tab) {
    if (panes == null) {
      panes = PaneLeaf(tab.id);
    } else if (!Panes.has(panes, tab.id)) {
      Panes.swap(panes, focusedTab?.id ?? Panes.order(panes).first, tab.id);
    }
    focusedPaneId = tab.id;
  }

  /// Tira a folha da árvore e reencosta o foco em quem ficou no lugar dela.
  void _drop(MxTab tab) {
    final before = Panes.order(panes);
    final at = before.indexOf(tab.id);
    panes = Panes.remove(panes, tab.id);
    if (focusedPaneId != tab.id) return;
    final left = Panes.order(panes);
    focusedPaneId = left.isEmpty ? null : left[at.clamp(0, left.length - 1)];
  }

  /// Tira o painel da tela sem encerrar nada.
  ///
  /// O X do header é isto, e [closeTab] é outra coisa. Uma sessão que saiu do
  /// painel continua na lateral com o processo, o scrollback e a fila que
  /// tinha -- ela só parou de ocupar a tela. Era o que faltava: o gesto mais
  /// à mão do header era o único que matava a conversa, então "chega de olhar
  /// pra isso" custava a sessão.
  void dismiss(MxTab tab) {
    if (!Panes.has(panes, tab.id)) return;
    // O espaço não fica vago: o corte em volta desaba e os painéis vizinhos
    // tomam conta do que sobrou, que é o que "fechar um dos quatro" quer
    // dizer numa grade.
    _drop(tab);
    _save();
    notifyListeners();
  }

  /// Encerra: mata o processo e apaga o painel da lateral. Para só limpar a
  /// tela, [dismiss].
  void closeTab(MxTab tab) {
    tab.pendingFollowUp?.cancel();
    tab.term.kill();
    tabs.remove(tab);
    _drop(tab);
    // Encerrar o último painel com sessões vivas na lateral deixaria a tela
    // limpa no meio do trabalho: quando não sobra painel nenhum, a última
    // sessão aberta ocupa o lugar.
    if (panes == null && tabs.isNotEmpty) _place(tabs.last);
    _save();
    notifyListeners();
  }

  void closeFocused() {
    final tab = focusedTab;
    if (tab != null) closeTab(tab);
  }

  /// Fecha de uma vez o que já não pede nada de você: o painel cujo processo
  /// saiu -- que empilha rápido enquanto se experimenta coisas -- e o que você
  /// marcou como concluído.
  ///
  /// [MxTab.done] sozinho nunca fecha nada -- marcar é um juízo, não um
  /// descarte, e o painel fica com o scrollback e a sessão pra reler ou
  /// retomar. Mas quando você pede a varrida, está dizendo justamente que
  /// terminou com essa leva; deixar de fora os concluídos obrigaria a fechar
  /// um por um exatamente os painéis que você já declarou resolvidos.
  void closeSettled(Folder p) {
    for (final t in tabsOf(p).where((t) => t.exited || t.done).toList()) {
      closeTab(t);
    }
  }

  void renameTab(MxTab tab, String label) {
    tab.customLabel = label;
    _save();
    notifyListeners();
  }

  /// Mark a session as having done its job, or take the mark back.
  ///
  /// Deliberately not a close. Closing says "I am done with this panel" and
  /// takes the conversation with it; this says "this one worked", which is
  /// something you want to be able to say about a session you are keeping --
  /// to reread, to resume, to point the next one at. What it buys is quiet:
  /// see [MxTab.done], [needingHuman] and [_checkAlerts].
  ///
  /// Returns how many queued steps went with it. Marking drops the queue,
  /// because a follow-up firing into a session you just called finished would
  /// be the app arguing with you -- and it is the one thing here you cannot
  /// see, so the caller is handed the number to say out loud.
  int setDone(MxTab tab, bool done) {
    if (tab.done == done) return 0;
    tab.done = done;
    var dropped = 0;
    if (done) {
      tab.pendingFollowUp?.cancel();
      tab.pendingFollowUp = null;
      dropped = tab.followUps.length;
      tab.followUps.clear();
    }
    _save();
    notifyListeners();
    return dropped;
  }

  /// Drop [tab] onto [target]'s place in the list, sliding the rest along.
  ///
  /// The list is one list while the sidebar draws it per folder, so a
  /// folder's panels are a subsequence of it and not a slice. Landing the
  /// panel on the target's index leaves every other panel's relative order
  /// untouched -- and with it the ⌘1..9 numbering, which is this same list
  /// counted from the top, and the saved layout, which is its order on disk.
  void moveTab(MxTab tab, MxTab target) {
    final from = tabs.indexOf(tab);
    final to = tabs.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    // After the removal the target sits at `to - 1` when the panel came from
    // above and at `to` when it came from below -- which is exactly the index
    // that puts the panel after it in the first case and before it in the
    // second. Both are the slot you dropped it on.
    tabs.removeAt(from);
    tabs.insert(to, tab);
    // Dropped among another project's panels, it joins that project: the list
    // it landed in is the answer to which job it is part of.
    tab.projectId = target.projectId;
    _save();
    notifyListeners();
  }

  // --- panes and keyboard -------------------------------------------------

  /// Solta [tab] em cima do painel de [target], pelo lado [side].
  ///
  /// Uma sessão aparece numa posição só: arrastar uma que já está na tela é
  /// mudá-la de lugar, então ela sai de onde estava antes de entrar onde caiu
  /// -- e o buraco que ela deixa fecha sozinho, igual ao que o x faria.
  void dropTab(MxTab tab, {required MxTab target, required DropSide side}) {
    // Solta em cima de si mesma: o gesto não vai a lugar nenhum, e um drag de
    // mouse começa com um pixel, então é o clique que ele quase foi.
    if (tab.id == target.id || !Panes.has(panes, target.id)) {
      focusPane(tab);
      return;
    }
    _drop(tab);
    if (side == DropSide.center) {
      Panes.swap(panes, target.id, tab.id);
    } else {
      panes = Panes.insert(panes!, tabId: tab.id, targetId: target.id, side: side);
    }
    focusedPaneId = tab.id;
    _save();
    notifyListeners();
  }

  /// Manda o teclado pro painel que mostra [tab]: um clique dentro dele.
  void focusPane(MxTab tab) {
    if (focusedPaneId == tab.id || !Panes.has(panes, tab.id)) return;
    focusedPaneId = tab.id;
    notifyListeners();
  }

  /// Passa o foco pro painel seguinte na tela, ou pro anterior.
  void cyclePane(int delta) {
    final order = Panes.order(panes);
    if (order.length < 2) return;
    final at = order.indexOf(focusedPaneId ?? order.first);
    final next = (at + delta) % order.length;
    focusedPaneId = order[next < 0 ? next + order.length : next];
    notifyListeners();
  }

  /// A alça entre dois painéis, arrastada. [total] é o quanto o corte mede no
  /// sentido dele, em pixels -- é o que transforma o delta do mouse na fração
  /// que fica guardada.
  void resizeSplit(PaneSplit split, int gutter, double delta, double total) {
    Panes.resize(split, gutter, delta, total);
    _save();
    notifyListeners();
  }

  void selectIndex(int index) {
    if (index < 0 || index >= tabs.length) return;
    select(tabs[index]);
  }

  /// Move the focused pane through the panel list.
  void cycle(int delta) {
    if (tabs.isEmpty) return;
    final current = tabs.indexWhere((t) => t.id == focusedTab?.id);
    final next = (current + delta) % tabs.length;
    select(tabs[next < 0 ? next + tabs.length : next]);
  }

  List<MxTab> tabsOf(Folder p) => tabs.where((t) => t.folderRoot == p.root).toList();

  int needingHuman(Folder p) => tabsOf(p).where((t) => !t.done && t.status.needsHuman).length;

  void showBanner(String text) {
    banner = text;
    notifyListeners();
  }

  void clearBanner() {
    banner = null;
    notifyListeners();
  }

  // --- incoming events ----------------------------------------------------

  /// One hook event, applied. Visible because the edge it watches for is the
  /// whole contract of a queue: one turn, one step.
  @visibleForTesting
  void applyHook(HookEvent e) {
    final tab = _byId(e.tabId);
    if (tab == null) return;
    final before = tab.hooks.status;
    final producedBefore = tab.hooks.touched.length;
    HookReducer.apply(tab.hooks, e.name, e.payload);
    // Asked for more, it is not finished any more. The mark is a judgement
    // about work that is over, and a prompt is the person who made it saying
    // it is not -- so the app takes their word for that too, rather than
    // leaving a tick on a session that is off doing something new.
    if (tab.done && e.name == 'UserPromptSubmit') {
      tab.done = false;
      _save();
    }
    if (tab.hooks.sessionId != null && tab.sessionId != tab.hooks.sessionId) {
      tab.sessionId = tab.hooks.sessionId;
      _save();
    }
    // A file the session just wrote is worth the debounced write: the whole
    // point of keeping the list is that it survives closing the window.
    if (tab.hooks.touched.length != producedBefore) _save();
    // The edge, not the state: `Stop` is the only event that reaches idle, but
    // a second one arriving while the panel is already idle must not spend
    // another step.
    if (before != ClaudeStatus.idle && tab.hooks.status == ClaudeStatus.idle) {
      advance(tab);
    }
    _checkAlerts();
    notifyListeners();
  }

  // --- follow-ups ---------------------------------------------------------

  /// Arm [tab] with what to do when it next goes quiet, replacing whatever
  /// was queued.
  void queue(MxTab tab, List<FollowUp> steps) {
    tab.followUps
      ..clear()
      ..addAll(steps);
    notifyListeners();
  }

  /// Spend the next queued step, if there is one.
  ///
  /// Visible because the guarantee worth testing is that one turn spends one
  /// step -- a queue that emptied itself on a single `Stop` would fire a plan's
  /// third instruction before its first had been read.
  @visibleForTesting
  void advance(MxTab tab) {
    if (tab.exited || tab.followUps.isEmpty) return;
    final step = tab.followUps.removeAt(0);
    // `Stop` fires when the turn ends, which is a beat before the prompt is
    // back and taking input. Handing it text in that gap loses the text.
    tab.pendingFollowUp?.cancel();
    tab.pendingFollowUp = Timer(followUpDelay, () => runFollowUp(step, from: tab));
    notifyListeners();
  }

  /// How long after a session goes quiet a queued step is delivered.
  @visibleForTesting
  static const followUpDelay = Duration(milliseconds: 700);

  /// Carry out one step. See [FollowUpKind] for what each one means.
  @visibleForTesting
  Future<void> runFollowUp(FollowUp step, {required MxTab from}) async {
    if (!tabs.contains(from)) return;
    final project = projectOf(from);

    switch (step.kind) {
      case FollowUpKind.keepGoing:
        if (from.exited) return;
        await from.term.submit(step.text);
        showBanner('${from.title}: próximo passo enviado');

      case FollowUpKind.newSession:
        final tab = openClaude(
          from.folder,
          cwd: from.cwd,
          label: '${from.title} ▸ depois',
          project: project,
          prompt: step.text,
        );
        showBanner('${from.title} terminou — abri ${tab.title} em seguida');

      case FollowUpKind.command:
        final shell = openShell(from.folder, cwd: from.cwd, command: step.text, project: project);
        shell.customLabel = '${from.title} ▸ depois';
        showBanner('${from.title} terminou — rodando ${step.text}');

      case FollowUpKind.handoff:
        final target = _byId(step.targetTabId);
        // A target closed in the meantime is not worth a dialog -- but it is
        // worth saying, because a handoff quietly not happening is the one
        // failure you would never notice.
        if (target == null || target.exited) {
          showBanner('${from.title} terminou, mas o painel que ia receber não está mais aberto');
          return;
        }
        await target.term.submit(handoffText(from, step.text));
        showBanner('${from.title} passou a bola pra ${target.title}');
    }
  }

  /// What one panel says to the next.
  ///
  /// The closing message crosses verbatim and fenced, because the receiving
  /// session has no other way to know what happened: it is a different process
  /// in a different conversation, and all it shares with the sender is the
  /// checkout on disk.
  @visibleForTesting
  static String handoffText(MxTab from, String note) {
    final said = _clipHandoff(from.hooks.lastMessageFull);
    final out = StringBuffer('[maestria] o painel "${from.title}" acabou de terminar.');
    if (said != null && said.isNotEmpty) {
      out.write('\n\nO que ele disse ao terminar:\n"""\n$said\n"""');
    }
    if (note.trim().isNotEmpty) out.write('\n\n${note.trim()}');
    return out.toString();
  }

  /// A closing message is whatever the model felt like writing, and it is
  /// about to be typed into somebody's prompt. The tail is what gets kept:
  /// what a session says last is what it concluded.
  static String? _clipHandoff(String? said) {
    const max = 4000;
    if (said == null || said.isEmpty) return said;
    return said.length <= max ? said : '…${said.substring(said.length - max)}';
  }

  /// One poll, applied: our own panels learn the session id the CLI gave
  /// them, which is what makes a restored panel resumable.
  ///
  /// Sessions we did not launch are ignored on purpose. Their pty belongs to
  /// somebody else's terminal, so there was nothing the sidebar could offer
  /// for them beyond a row taking up space.
  @visibleForTesting
  void applyAgents(List<AgentInfo> list) {
    final ourPids = {
      for (final t in tabs)
        if (t.term.pid != null) t.term.pid!: t,
    };
    for (final a in list) {
      final mine = a.pid == null ? null : ourPids[a.pid];
      if (mine == null) continue;
      // O nome vem antes do id na vida de uma sessão e vale por si: é por ele
      // que se fala com ela.
      if (a.name != null && a.name!.isNotEmpty) mine.agentName = a.name;
      if (a.sessionId == null) continue;
      mine.sessionId = a.sessionId;
    }
    _checkAlerts();
  }

  /// Notify once per session that stops for a human, and keep the dock badge
  /// equal to how many are stopped right now.
  void _checkAlerts() {
    final waiting = <String, String>{};
    for (final t in tabs) {
      if (!t.done && t.status.needsHuman) {
        waiting['tab:${t.id}'] = '${t.title} · ${t.status.callToAction}';
      }
    }

    for (final entry in waiting.entries) {
      if (_alerted.add(entry.key)) {
        notifier.alert('maestria', entry.value);
      }
    }
    _alerted.removeWhere((key) => !waiting.containsKey(key));
    notifier.badge(waiting.isEmpty ? null : '${waiting.length}');
  }

  @override
  void dispose() {
    // A write that was still waiting out its debounce has nothing left to
    // write about: the panels it would describe are being killed right here.
    _saveDebounce?.cancel();
    agents.stop();
    hooks.stop();
    for (final t in tabs) {
      t.pendingFollowUp?.cancel();
      t.term.kill();
    }
    super.dispose();
  }
}
