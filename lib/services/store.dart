import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../models.dart';
import '../theme.dart';
import 'agents.dart';
import 'docs.dart';
import 'editor.dart';
import 'git.dart';
import 'history.dart';
import 'hooks.dart';
import 'layout.dart';
import 'links.dart';
import 'notify.dart';
import 'paths.dart';
import 'pty.dart';
import 'report.dart';
import 'shell.dart';
import 'shortcuts.dart';

/// O que um painel é.
///
/// [reader] é o de fora: não tem processo, não tem pty e não tem sessão -- é um
/// documento na árvore de painéis, do mesmo tamanho e com o mesmo cabeçalho
/// que os outros. Ver [MxDoc], e `ui/doc_pane.dart` pra como ele é desenhado.
enum TabKind { shell, claude, reader }

/// One panel. Owns its pty and its hook-derived state.
class MxTab {
  MxTab({
    required this.id,
    required this.folder,
    required this.kind,
    required this.cwd,
    required this.branch,
    this.customLabel,
    this.doc,
    this.launcher,
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

  /// O que este painel mostra, quando ele é um [TabKind.reader]. Null em todos
  /// os outros -- e não-null em todos os readers, que é o que [isReader]
  /// garante pra quem vai desreferenciar.
  final MxDoc? doc;

  /// Um painel de leitura: nada aqui tem processo, fila, git ou estado de
  /// sessão pra dizer. Meia dúzia de lugares perguntam isso antes de tratar
  /// este painel como uma sessão.
  bool get isReader => kind == TabKind.reader && doc != null;

  /// O programa que este painel subiu, quando ele saiu de um. Ver [Launcher].
  ///
  /// Por referência, como a [folder]: renomear o programa renomeia os painéis
  /// dele, e trocar o comando vale no próximo "rodar de novo". Vira null
  /// quando o programa é apagado -- o painel continua o terminal que sempre
  /// foi, com o que estiver rodando dentro dele, em vez de sumir junto com a
  /// linha que o abriu.
  Launcher? launcher;

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

  /// O ⌘+ deste painel: passos de um ponto sobre o corpo base ([MxType.size]).
  ///
  /// Do painel e não da janela de propósito — numa grade de quatro, um deles é
  /// o que você está lendo de perto e os outros três são de canto de olho. E
  /// em passos, não em tamanho, pra que trocar a base nas configurações leve
  /// todos junto sem apagar a diferença que cada um pediu.
  int zoom = 0;

  /// O corpo com que o pty deste painel é desenhado. Um leitor não passa por
  /// aqui: ele soma os mesmos passos à escala do markdown, que é outra.
  double get fontSize => Mx.type.sizeAt(zoom);

  /// O grupo de que este painel faz parte, se faz de algum. Ver [PaneGroup].
  ///
  /// Um só, e o último em que ele entrou: dois grupos podem conter a mesma
  /// sessão, e a linha da lateral tem uma cor e um clique -- não dois. Quem
  /// grava e limpa isto é [AppStore._stamp], sempre a partir do grupo inteiro.
  String? groupId;

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
    // Um documento se chama pelo que ele é: o nome do arquivo, "plano de
    // TASK#47730", "relatório do dia". A pasta e a branch não dizem nada sobre
    // ele que o título já não diga melhor.
    if (doc case final open?) return open.title;
    // E um painel de programa se chama pelo programa: "btop", e não pelo repo
    // em que ele por acaso subiu. Mesmo raciocínio do documento acima -- a
    // pasta e a branch não dizem nada dele que o nome não diga melhor.
    if (launcher case final l?) return l.name;
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
    if (doc case final open?) {
      final when =
          '${open.at.hour.toString().padLeft(2, '0')}:'
          '${open.at.minute.toString().padLeft(2, '0')}';
      if (open.missing) return '${open.source.label} · o arquivo não está mais lá';
      // A origem e a hora, que são as duas perguntas que um documento aberto
      // levanta: de onde ele saiu, e se é o de agora ou o de duas horas atrás.
      // A origem sai quando o título já a carrega -- "plano de TASK#47730" com
      // "de TASK#47730" embaixo é o cabeçalho dizendo a mesma coisa duas vezes.
      final from = open.origin;
      final says = from != null && from.isNotEmpty && !title.contains(from);
      return [open.source.label, if (says) 'de $from', when].join(' · ');
    }
    if (exited) return 'processo saiu (${term.exitCode ?? '?'})';
    // O comando, que é a única coisa que o cabeçalho ainda não disse: o nome
    // do programa já é o título, e "programa" embaixo dele não informaria
    // nada. `npm run dev` embaixo de "dev" informa.
    if (launcher case final l?) return l.command;
    if (kind == TabKind.shell) return 'shell';
    return hooks.subtitle;
  }

  bool get exited => term.exited;

  /// O id que um `--resume` desta sessão levaria: o que o painel anotou, ou o
  /// que os hooks contaram.
  String? get resumeId => sessionId ?? hooks.sessionId;

  /// A conversa dá pra retomar, com ou sem processo vivo.
  ///
  /// A distinção que faltava: sair do processo não é perder a sessão. É o que
  /// mandar a sessão pro background faz -- o claude solta o terminal e segue
  /// rodando fora dele --, e é o que um `/exit` faz também; nos dois casos o
  /// que ficou pra trás é uma conversa endereçada por um id, que é justamente
  /// o que o painel volta a abrir. Ver [AppStore._writeConfig], que é quem
  /// tratava esse painel como um painel morto.
  bool get resumable => kind == TabKind.claude && resumeId != null;

  /// Um leitor nunca está fazendo nada: ele é uma folha de papel. Fica em
  /// [ClaudeStatus.unknown], que é o estado que não acende badge, não conta
  /// como pendência e não notifica.
  ClaudeStatus get status => switch (kind) {
    TabKind.reader => ClaudeStatus.unknown,
    TabKind.shell => exited ? ClaudeStatus.ended : ClaudeStatus.unknown,
    TabKind.claude => hooks.status,
  };

  /// A receita do painel: o que basta pra abrir *um igual* a este.
  ///
  /// A metade do [toJson] que descreve o painel em vez do que passou dentro
  /// dele -- e é por isso que ela tem nome próprio: um grupo salvo (ver
  /// [PaneGroup]) guarda arranjo, não história. Quem remonta um painel destes,
  /// dos dois lados, é [AppStore._openPane].
  Map<String, dynamic> get recipe => {
    'folderRoot': folder.root,
    if (folder.isLoose) 'loose': true,
    if (projectId != null) 'projectId': projectId,
    'kind': kind.name,
    'cwd': cwd,
    // Só o id: o nome e o comando são do programa, não do painel, e uma cópia
    // deles aqui voltaria amanhã com o comando de ontem depois de você editar
    // o programa. Um id que não existe mais volta como terminal -- ver
    // [AppStore._openPane].
    if (launcher case final l?) 'launcher': l.id,
    if (customLabel != null) 'label': customLabel,
    // The session id is the whole point: a restored panel resumes the
    // conversation instead of starting a stranger in the same folder.
    if (resumable) 'sessionId': resumeId,
    if (doc case final open?) 'doc': open.toJson(),
    // Uma sessão que você deixou grande é uma sessão que você quer grande
    // amanhã também — e é uma tecla, não uma preferência, então não tem outro
    // lugar onde ser lembrada.
    if (zoom != 0) 'zoom': zoom,
  };

  /// What it takes to bring this panel back next time the app opens.
  Map<String, dynamic> toJson() => {
    ...recipe,
    // Fora da receita de propósito: a receita é o que um grupo guarda, e um
    // grupo guardando a que grupo o painel pertence seria ele apontando pra
    // si mesmo. Aqui, no layout, é o que faz a cor da linha e o clique dela
    // sobreviverem ao fechamento da janela.
    if (groupId != null) 'group': groupId,
    // Unlike the queue, which is armed for a session running *now*, what the
    // work produced outlives the session that produced it: the six files are
    // still the six files tomorrow morning.
    if (hooks.touched.isNotEmpty) 'touched': hooks.touched,
    // Pelo mesmo motivo dos arquivos, e com mais razão: o plano é o documento
    // que sobreviveu ao turno, e o hook que o trouxe não acontece de novo. Um
    // restart que o esquecesse apagaria a única cópia que existe dele.
    if (hooks.plans.isNotEmpty) 'plans': hooks.plans.map((n) => n.toJson()).toList(),
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

  /// Os arranjos que você salvou. Ver [PaneGroup] -- e [saveGroup], que é o
  /// gesto que põe um aqui.
  ///
  /// Fora das pastas de propósito, como a lista de painéis: um grupo pode
  /// juntar painéis de repos diferentes, então pendurá-lo numa pasta seria
  /// escolher uma das duas por ele.
  final List<PaneGroup> groups = [];

  /// Os programas que você ensinou ao maestria. Ver [Launcher] -- e
  /// [openLauncher], que é o que uma linha do menu do + faz.
  ///
  /// Fora das pastas como os grupos, e pelo mesmo motivo: `btop` não é do repo
  /// em que você o abriu primeiro. Um programa é uma forma de abrir painel, e
  /// vale em qualquer pasta da lateral.
  final List<Launcher> launchers = [];

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

  /// A pasta onde a janela guarda o que ela lembra. Ver [mxStateHome] -- mora
  /// em `services/paths.dart` porque o [HookServer] anota a porta dele ali
  /// também, e ele sobe antes de existir store pra perguntar.
  static String get stateHome => mxStateHome;

  File get _configFile => File('$mxStateDir/config.json');

  @visibleForTesting
  String get configPath => _configFile.path;

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
      for (final g in (j['groups'] as List? ?? const [])) {
        if (PaneGroup.fromJson(g) case final group?) groups.add(group);
      }
      // Antes do layout de propósito: os painéis salvos apontam pra cá pelo
      // id, e um painel de `btop` restaurado antes da lista existir voltaria
      // como um terminal qualquer.
      for (final l in (j['launchers'] as List? ?? const [])) {
        if (Launcher.fromJson(l) case final launcher?) launchers.add(launcher);
      }
      final w = (j['sidebarWidth'] as num?)?.toDouble();
      if (w != null) sidebarWidth = w.clamp(minSidebar, maxSidebar);
      Mx.applyId(j['theme'] as String?);
      Mx.applyType(MxType.fromJson(j['type']));
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
    // Uma posição por painel salvo, com null onde não deu pra voltar: as
    // folhas da árvore são índices desta lista, então uma lista que só junta
    // os que vingaram deslocaria todas as folhas depois do painel que faltou.
    final restored = <MxTab?>[];
    for (final pane in saved) {
      final tab = _openPane(pane);
      restored.add(tab);
      if (tab == null) continue;
      tab.hooks.touched.addAll((pane['touched'] as List? ?? const []).whereType<String>());
      tab.hooks.plans.addAll(
        (pane['plans'] as List? ?? const []).map(PlanNote.fromJson).whereType<PlanNote>(),
      );
      tab.done = pane['done'] == true;
      // Só se o grupo ainda existir: um grupo esquecido no meio do caminho
      // deixaria as linhas coloridas de um conjunto que não abre mais.
      final group = pane['group'] as String?;
      if (groups.any((g) => g.id == group)) tab.groupId = group;
    }
    _restoring = false;

    final count = restored.nonNulls.length;
    if (count == 0) return;
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
    banner = '$count painéis restaurados da última sessão';
    notifyListeners();
  }

  /// Abre o painel que [pane] descreve -- a receita de [MxTab.recipe].
  ///
  /// Um lugar só pra isso porque duas coisas remontam painéis a partir do
  /// mesmo json: o layout da última execução e um grupo salvo (ver
  /// [openGroup]). Null é o painel que não tem mais onde abrir: a pasta saiu
  /// da lateral, o cwd não existe, o documento não voltou.
  MxTab? _openPane(Map<String, dynamic> pane) {
    final root = (pane['folderRoot'] ?? pane['projectRoot']) as String?;
    final folder = pane['loose'] == true
        ? loose
        : folders.firstWhereOrNull((f) => f.root == root);
    final cwd = pane['cwd'] as String?;
    if (folder == null || cwd == null || !Directory(cwd).existsSync()) return null;
    final label = pane['label'] as String?;
    final project = projectById(pane['projectId'] as String?);
    final MxTab tab;
    if (pane['kind'] == 'reader') {
      // Um leitor volta como o documento que era: um arquivo se relê do
      // disco na montagem do painel, e um plano volta do texto que foi
      // salvo com ele. Sem documento não há painel -- e é melhor não voltar
      // do que voltar uma folha em branco onde havia um plano.
      final doc = MxDoc.fromJson(
        (pane['doc'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      if (doc == null) return null;
      tab = _newReader(doc, folder: folder, cwd: cwd, project: project);
    } else if (pane['kind'] == 'claude') {
      tab = openClaude(
        folder,
        cwd: cwd,
        label: label,
        project: project,
        resumeId: pane['sessionId'] as String?,
      );
    } else {
      // Um painel de programa volta rodando o programa: o `btop` que você
      // deixou aberto é `btop` de novo, e não um prompt parado na pasta dele.
      // O programa apagado no meio do caminho devolve o terminal que o painel
      // sempre foi por baixo -- é menos do que você deixou, mas é o painel.
      tab = openShell(
        folder,
        cwd: cwd,
        project: project,
        launcher: launcherById(pane['launcher'] as String?),
      );
    }
    if (label != null) tab.customLabel = label;
    // Contido pela base de agora: quem baixou o corpo nas configurações
    // desde a última vez não recebe um painel fora do limite.
    tab.zoom = Mx.type.clampZoom((pane['zoom'] as num?)?.toInt() ?? 0);
    return tab;
  }

  void _save() {
    if (_restoring) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _writeConfig);
  }

  Future<void> _writeConfig() async {
    try {
      await _configFile.parent.create(recursive: true);
      // Painel com processo vivo, mais o que ainda tem conversa pra retomar --
      // ver [MxTab.resumable]. Descartar todo painel sem processo era descartar
      // a sessão que foi pro background junto com o terminal morto: o claude
      // sai do pty e continua rodando, e era esse id que fazia falta na volta.
      final open = tabs.where((t) => !t.exited || t.resumable).toList();
      final tree = Panes.toJson(panes, (id) => open.indexWhere((t) => t.id == id));
      await _configFile.writeAsString(
        jsonEncode({
          'folders': folders.map((f) => f.toJson()).toList(),
          'projects': projects.map((p) => p.toJson()).toList(),
          // Ao lado do layout e escritos com o mesmo json que ele: um grupo é
          // um layout guardado com nome. Ver [PaneGroup].
          if (groups.isNotEmpty) 'groups': groups.map((g) => g.toJson()).toList(),
          if (launchers.isNotEmpty)
            'launchers': launchers.map((l) => l.toJson()).toList(),
          'sidebarWidth': sidebarWidth,
          'theme': Mx.palette.id,
          if (Mx.type.toJson() case final type when type.isNotEmpty) 'type': type,
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

  /// Reescreve o pty em [type] e guarda a escolha. Vale na hora, em todo
  /// painel — o xterm remede a célula e o pty é redimensionado junto.
  void setTypography(MxType type) {
    if (type == Mx.type) return;
    Mx.applyType(type);
    _save();
    notifyListeners();
  }

  /// ⌘+ e ⌘− no painel em foco, em passos.
  ///
  /// Um leitor responde também: a pergunta que a tecla faz é sobre o painel,
  /// não sobre o pty, e um plano lido de perto é o mesmo pedido.
  void zoomFocused(int by) {
    final tab = focusedTab;
    if (tab == null) return;
    final zoom = Mx.type.clampZoom(tab.zoom + by);
    if (zoom == tab.zoom) return;
    tab.zoom = zoom;
    _save();
    notifyListeners();
  }

  /// ⌘0: devolve o painel em foco ao corpo base.
  void resetZoomFocused() {
    final tab = focusedTab;
    if (tab == null || tab.zoom == 0) return;
    tab.zoom = 0;
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

  Future<Folder?> addFolder(String rawPath) async {
    // O caminho vem de um campo de texto, e num campo de texto se digita `~/`
    // -- ver [expandHome]. Aqui em cima porque tudo abaixo (o `git` da pasta, o
    // `existsSync`, o que vai pro config) já tem que estar falando do lugar de
    // verdade.
    final path = expandHome(rawPath);
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

  MxTab openShell(
    Folder f, {
    String? cwd,
    String? command,
    Project? project,
    Launcher? launcher,
  }) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: f,
      kind: TabKind.shell,
      cwd: cwd ?? f.root,
      branch: '',
      launcher: launcher,
    );
    if (project != null && project.folderRoot == f.root) tab.projectId = project.id;
    _register(tab);
    // O comando do programa, quando quem chamou não trouxe um: é o que faz
    // "abrir o btop" abrir o btop, e não um prompt onde você digitaria btop.
    final run = command ?? launcher?.command;
    if (run == null) {
      tab.term.startShell(tab.cwd);
    } else {
      tab.term.startCommand(run, tab.cwd);
    }
    return tab;
  }

  /// Abre [launcher] numa pasta: um terminal que já sobe dentro do programa.
  ///
  /// O mesmo caminho de [openShell] -- porque é isso que ele é. O que o
  /// programa acrescenta é o de fora do pty: o nome no cabeçalho, o desenho na
  /// lateral, e o painel voltando amanhã rodando a mesma coisa.
  MxTab openLauncher(Launcher launcher, Folder f, {String? cwd, Project? project}) =>
      openShell(f, cwd: cwd, project: project, launcher: launcher);

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

  // --- histórico de conversas ---------------------------------------------

  /// As conversas que já rodaram em [folder]. Ver `services/history.dart`.
  ///
  /// Da pasta *e das worktrees dela*, porque uma conversa é da worktree em que
  /// aconteceu -- e o trabalho aqui mora em worktree: filtrar só pelo checkout
  /// principal esconderia justamente as conversas de task. A bandeja dos
  /// avulsos é a exceção e recebe o histórico inteiro: ela é onde se vai
  /// quando nenhuma das pastas de cima é a resposta, e uma conversa que se
  /// procura sem saber mais onde rodou é esse caso.
  Future<List<ChatEntry>> chatsIn(Folder folder) => ChatHistory.read(
    root: chatHome,
    cwds: folder.isLoose
        ? null
        : [folder.root, ...?worktrees[folder.root]?.map((w) => w.path)],
  );

  /// De onde as conversas são lidas. Sob teste, as fixtures -- pela mesma
  /// razão de [stateHome]: um `flutter test` que fosse ao `~/.claude` de
  /// verdade dependeria das conversas que a máquina de quem rodou teve.
  static String get chatHome => Platform.environment.containsKey('FLUTTER_TEST')
      ? 'test/fixtures/history'
      : ChatHistory.home;

  /// Em que pé está [chat] agora. Ver [ChatStanding].
  ChatStanding standingOf(ChatEntry chat) {
    if (tabs.any((t) => t.resumeId == chat.sessionId)) return ChatStanding.onScreen;
    // Viva é o que o `claude agents --json` lista: ele só enxerga processo de
    // pé, que é a razão de ele não servir de histórico -- e a razão de servir
    // exatamente pra isto.
    if (agents.latest.any((a) => a.sessionId == chat.sessionId)) return ChatStanding.live;
    if (chat.missing || chat.cwd.isEmpty || !Directory(chat.cwd).existsSync()) {
      return ChatStanding.gone;
    }
    return ChatStanding.fresh;
  }

  /// Retoma [chat] num painel: o `--resume` daquela conversa, na pasta em que
  /// ela rodou.
  ///
  /// As três recusas são as de [ChatStanding], e a linha do histórico já as
  /// mostrava antes do clique -- o aviso aqui é pra quem clicou de qualquer
  /// jeito, ou pra quando a sessão subiu entre a leitura da lista e o clique.
  MxTab? resumeChat(ChatEntry chat, {Folder? folder, Project? project}) {
    switch (standingOf(chat)) {
      case ChatStanding.onScreen:
        // Não é pra abrir de novo: é pra olhar. Uma segunda sessão no mesmo id
        // seria o CLI recusando por sessão viva -- a que o próprio cockpit
        // acabou de subir.
        final open = tabs.firstWhere((t) => t.resumeId == chat.sessionId);
        select(open);
        return open;
      case ChatStanding.live:
        showBanner(
          '"${chat.label}" ainda está rodando fora do maestria — '
          'o claude só retoma uma conversa depois que ela sai',
        );
        return null;
      case ChatStanding.gone:
        showBanner(
          chat.cwd.isEmpty
              ? 'não sei em que pasta "${chat.label}" rodou'
              : 'a pasta dessa conversa não existe mais: ${chat.cwd}',
        );
        return null;
      case ChatStanding.fresh:
        break;
    }
    // A pasta que o cockpit conhece pra esse caminho, quando quem pediu não
    // disse: o histórico inteiro traz conversa de repo que não está na lateral,
    // e essa entra nos avulsos.
    final at =
        folder ??
        folders.firstWhereOrNull((f) => chat.cwd == f.root || chat.cwd.startsWith('${f.root}/')) ??
        loose;
    return openClaude(
      at,
      cwd: chat.cwd,
      // O painel se chama pela conversa. Sem isto ele viria com o nome da
      // pasta, igual a todos os outros dali -- e o que se acabou de escolher
      // numa lista de quarenta foi *aquela* conversa.
      label: chat.label,
      resumeId: chat.sessionId,
      project: project,
    );
  }

  // --- painéis de leitura -------------------------------------------------

  /// Põe [doc] na tela, num painel de leitura. Ver [TabKind.reader].
  ///
  /// Reaproveita o leitor que já estiver aberto, quando há um: um leitor é um
  /// *lugar*, do mesmo jeito que um painel de terminal é um lugar, e abrir
  /// quatro `.md` seguidos é trocar o que está naquele lugar quatro vezes --
  /// não picar a janela em quatro. Sem nenhum aberto, o documento entra ao
  /// lado do painel de onde saiu e não em cima dele: quem clica em "ver o
  /// plano" quer o plano *e* a sessão que o escreveu.
  MxTab showDoc(MxDoc doc, {MxTab? from}) {
    final source = from ?? focusedTab;
    // O que está na tela primeiro; depois um que tenha saído dela -- um leitor
    // que alguém tirou do painel continua sendo *o* leitor, e abrir o próximo
    // documento num segundo deixaria dois na lateral pra sempre.
    final reading =
        openPanes.firstWhereOrNull((t) => t.isReader) ?? tabs.firstWhereOrNull((t) => t.isReader);
    if (reading != null) {
      reading.doc!.become(doc);
      // O apelido era o nome do documento anterior. Um leitor renomeado à mão
      // que passa a mostrar outra coisa mentiria no cabeçalho.
      reading.customLabel = null;
      if (!Panes.has(panes, reading.id)) _placeBeside(reading, source);
      focusedPaneId = reading.id;
      _save();
      notifyListeners();
      return reading;
    }
    final tab = _newReader(
      doc,
      folder: source?.folder ?? focusedFolder,
      cwd: source?.cwd,
      project: source == null ? null : projectOf(source),
    );
    _placeBeside(tab, source);
    _save();
    notifyListeners();
    return tab;
  }

  /// O plano de uma sessão, aberto pra ler. Sem [note], o da vez.
  MxTab? showPlan(MxTab tab, [PlanNote? note]) {
    final plan = note ?? tab.hooks.plan;
    if (plan == null) {
      showBanner('${tab.title} não apresentou nenhum plano ainda');
      return null;
    }
    final which = tab.hooks.plans.indexOf(plan);
    final versioned = which >= 0 && which < tab.hooks.plans.length - 1
        ? 'plano ${which + 1}/${tab.hooks.plans.length}'
        : 'plano';
    return showDoc(
      MxDoc(
        source: DocSource.plan,
        title: '$versioned de ${tab.title}',
        text: plan.text,
        origin: tab.title,
        at: plan.at,
      ),
      from: tab,
    );
  }

  /// O último recado da sessão, que é markdown e era lido como texto cru.
  MxTab? showMessage(MxTab tab) {
    final said = tab.hooks.lastMessageFull;
    if (said == null || said.trim().isEmpty) {
      showBanner('${tab.title} ainda não disse nada ao terminar um turno');
      return null;
    }
    return showDoc(
      MxDoc(
        source: DocSource.message,
        title: 'recado de ${tab.title}',
        text: said,
        origin: tab.title,
      ),
      from: tab,
    );
  }

  /// Um `.md` do disco. O painel relê sozinho enquanto estiver aberto.
  MxTab? showFile(String path, {MxTab? from}) {
    if (!File(path).existsSync()) {
      showBanner('esse arquivo não está mais lá: $path');
      return null;
    }
    return showDoc(MxDoc.file(path, origin: from?.title), from: from);
  }

  /// Um link, seguido.
  ///
  /// A mesma resposta pros dois lugares em que se clica num link, porque é o
  /// mesmo gesto: o leitor de markdown, que sabe onde os links dele estão, e o
  /// terminal, onde eles são texto como o resto e alguém tem que reconhecê-los
  /// (ver `services/links.dart`). Um `.md` abre no leitor — que é o "por
  /// dentro do maestria" que o app tem —, outro arquivo vai pro Quick Look, e
  /// endereço de fora sai pro navegador: aqui não há onde desenhar uma página.
  ///
  /// [base] é a pasta contra a qual um caminho relativo é resolvido: a do
  /// arquivo que trouxe o link, ou a da sessão que o imprimiu.
  Future<void> followLink(String href, {MxTab? from, String? base}) async {
    if (href.trim().isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri != null && const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
      final ok = await Notifier.openLink(href);
      if (!ok) showBanner('não consegui abrir $href');
      return;
    }
    // Só a parte que é caminho: a âncora depois do # não é um arquivo, e o
    // leitor não tem pra onde rolar até ela.
    final path = href.split('#').first;
    if (path.isEmpty) return;
    final target = resolveLinkPath(path, base: base ?? from?.cwd);
    if (!File(target).existsSync()) {
      showBanner('esse link aponta pra um arquivo que não existe: $target');
      return;
    }
    if (readable(target)) {
      showFile(target, from: from);
      return;
    }
    await Notifier.quickLook(target);
  }

  /// Um markdown escolhido à mão, aberto no leitor.
  ///
  /// A porta que faltava. Tudo o mais aqui abre um documento que o cockpit viu
  /// nascer — o plano veio pelo hook, o `.md` veio da tira de arquivos
  /// alterados, que é o que as ferramentas de escrita anunciaram. Um arquivo
  /// escrito por `cat >`, um de ontem, ou um caminho que a sessão te devolveu
  /// no meio de uma frase não estão em lista nenhuma, e o scrollback não é
  /// clicável: sem isto, a única saída era o Finder.
  ///
  /// Não filtra por extensão de propósito: o painel nativo já só oferece texto,
  /// e um `.txt` que alguém escolheu é um `.txt` que alguém quis ler.
  Future<void> openMarkdown({MxTab? from}) async {
    final tab = from ?? focusedTab;
    final picked = await Notifier.chooseMarkdown(startIn: tab?.cwd ?? focusedFolder.root);
    if (picked == null) return;
    showFile(picked, from: tab);
  }

  /// O documento que o leitor está mostrando agora, se há um leitor na tela.
  ///
  /// Quem pergunta é a barra de documentos de um painel: com o plano e três
  /// `.md` oferecidos ali, o que ela precisa dizer é qual deles é o que está
  /// aberto -- senão clicar duas vezes na mesma ficha parece não ter feito nada.
  MxDoc? get reading => openPanes.firstWhereOrNull((t) => t.isReader)?.doc;

  /// Se o markdown deste caminho vale um leitor em vez do Quick Look.
  static bool readable(String path) => isMarkdownPath(path);

  MxTab _newReader(MxDoc doc, {required Folder folder, String? cwd, Project? project}) {
    final tab = MxTab(
      id: 'tab${_seq++}',
      folder: folder,
      kind: TabKind.reader,
      cwd: cwd ?? folder.root,
      branch: '',
      doc: doc,
    );
    if (project != null && project.folderRoot == folder.root) tab.projectId = project.id;
    // Não passa pelo [_register]: não há processo pra subir nem saída de
    // processo pra escutar, e a colocação na tela é outra (ao lado, não em
    // cima).
    tabs.add(tab);
    return tab;
  }

  /// Encaixa [tab] à direita do painel de [beside], quando há um na tela.
  void _placeBeside(MxTab tab, MxTab? beside) {
    if (panes == null || beside == null || !Panes.has(panes, beside.id)) {
      _place(tab);
      return;
    }
    panes = Panes.insert(panes!, tabId: tab.id, targetId: beside.id, side: DropSide.right);
    focusedPaneId = tab.id;
  }

  // --- relatório do dia ---------------------------------------------------

  /// Se o relatório está sendo escrito agora. Uma volta ao `claude -p` leva
  /// dezenas de segundos, e um botão que não diz isso parece um botão quebrado.
  bool get writingReport => _writingReport;
  bool _writingReport = false;

  /// O dia, reunido e contado de volta, num painel de leitura.
  ///
  /// O material é levantado aqui -- commits, worktrees sujas, as sessões desta
  /// janela -- e só a prosa é pedida ao Claude; ver [DailyReport]. Quando não
  /// dá, o painel abre com o material bruto e o motivo em cima dele: um
  /// resumo que não deu pra escrever ainda tem o dia inteiro dentro.
  Future<void> openDailyReport() async {
    if (_writingReport) return;
    _writingReport = true;
    showBanner('relatório do dia: reunindo o material e pedindo a prosa ao claude…');
    try {
      final material = await DailyReport.material(
        folders: folders,
        worktrees: worktrees,
        projects: projects,
        // Um leitor não é uma sessão: não rodou nada, não mexeu em nada e não
        // tem o que reportar sobre o dia.
        sessions: [
          for (final t in tabs)
            if (!t.isReader) _noteOf(t),
        ],
      );
      final outcome = await DailyReport.ask(material);
      showBanner(
        outcome.ok
            ? 'relatório do dia pronto'
            : 'não deu pra escrever o relatório — abri o material bruto',
      );
      showDoc(
        MxDoc(
          source: DocSource.report,
          title: 'relatório do dia',
          text: outcome.ok
              ? outcome.text
              : '# o relatório não saiu\n\n${outcome.text}\n\n---\n\n${outcome.material}',
          at: outcome.at,
        ),
      );
    } finally {
      _writingReport = false;
      notifyListeners();
    }
  }

  /// Um painel, achatado no que o relatório sabe ler.
  SessionNote _noteOf(MxTab t) => SessionNote(
    title: t.title,
    folder: t.folder.isLoose ? 'avulsos' : t.folder.name,
    // O programa, quando o painel é de um: "btop" diz mais ao relatório do
    // que "shell" -- que é o que todo painel de programa era aqui.
    kind: t.kind == TabKind.claude ? 'claude' : (t.launcher?.name ?? 'shell'),
    status: t.status.label,
    startedAt: t.startedAt,
    project: projectOf(t)?.name,
    branch: t.branch,
    prompts: t.hooks.prompts,
    tools: t.hooks.tools,
    touched: t.hooks.touched,
    lastPrompt: t.hooks.lastPrompt,
    lastMessage: t.hooks.lastMessage,
    exited: t.exited,
  );

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

  /// Põe [tab] na tela -- o clique numa linha da lateral.
  ///
  /// Quando a tela *é* um grupo (ver [activeGroup]), escolher uma sessão que
  /// não é dele não troca um quadro da grade: a grade sai inteira e a sessão
  /// escolhida fica com a tela. É o "se eu clicar em outro painel que não está
  /// no grupo, ele substitui o grupo inteiro por esse".
  ///
  /// Fora de um grupo continua valendo o que [_place] documenta -- trocar o
  /// que está no lugar em foco. A distinção é o ponto: uma grade que você
  /// montou à mão e não agrupou é sua, e um clique numa quarta sessão não pode
  /// desmanchá-la sem você ter pedido; uma grade que é um grupo tem pra onde
  /// voltar, porque está guardada.
  void select(MxTab tab) {
    final group = activeGroup;
    if (group != null && tab.groupId != group.id) {
      panes = PaneLeaf(tab.id);
      focusedPaneId = tab.id;
    } else {
      _place(tab);
    }
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
    // Sem await de propósito: [TermSession.kill] espera o hangup ser atendido
    // antes de escalar, e a tela não tem nada a ganhar parada esperando por
    // isso. O painel sai da lateral agora; o processo termina de morrer
    // sozinho, com quem ele subiu junto.
    unawaited(tab.term.kill());
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

  // --- grupos de painéis --------------------------------------------------

  /// Guarda o arranjo que está na tela como um grupo chamado [name]. Ver
  /// [PaneGroup].
  ///
  /// A tela é a fonte, e não uma lista de painéis pra marcar: "salvar um
  /// grupo" é arrumar a grade do jeito que ela serve e dizer que é assim que
  /// ela abre. Salvar com o nome de um grupo que já existe atualiza aquele
  /// grupo em vez de criar um homônimo -- dois "grid da manhã" na lateral
  /// seriam duas linhas iguais e nenhuma forma de saber qual é qual.
  ///
  /// Null com a tela limpa ou sem nome: não há arranjo pra guardar.
  PaneGroup? saveGroup(String name) {
    final title = name.trim();
    final open = openPanes;
    if (title.isEmpty || open.isEmpty) return null;
    final at = groups.indexWhere((g) => g.name.toLowerCase() == title.toLowerCase());
    final group = PaneGroup(
      // Numa atualização, o id do grupo que estava ali: é o mesmo grupo, com
      // outro arranjo dentro. Ver [addProject] pro formato.
      id: at < 0 ? 'gp${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}' : groups[at].id,
      name: title,
      panes: [for (final t in open) t.recipe],
      // O mesmo json que o layout salvo leva, e com as folhas apontando pra
      // lista que acabou de ser escrita: quem remonta a árvore, dos dois
      // lados, é o `Panes.fromJson`.
      tree: Panes.toJson(panes, (id) => open.indexWhere((t) => t.id == id)),
    );
    if (at < 0) {
      groups.add(group);
    } else {
      groups[at] = group;
    }
    _stamp(group, open);
    _save();
    notifyListeners();
    return group;
  }

  /// Agrupa os painéis que estão na tela -- o "agrupar painéis" do botão
  /// direito de um painel.
  ///
  /// Não pede nome: o gesto é apontar pra grade que já está montada e dizer
  /// que aqueles painéis andam juntos, e um diálogo no meio disso cobraria uma
  /// decisão que ninguém tinha pra tomar. O nome sai do que o grupo abre ("3
  /// terminais"), com um número atrás quando já existe um assim -- e trocar
  /// por um nome de gente é o "renomear" do menu do grupo.
  ///
  /// Null com menos de dois painéis na tela: um painel sozinho não é grade.
  PaneGroup? groupPanes() {
    final open = openPanes;
    if (open.length < 2) return null;
    final base = PaneGroup.summarize([for (final t in open) t.recipe]);
    // Nome novo e não o de um grupo existente: cair no nome de outro faria
    // [saveGroup] atualizar aquele grupo em vez de criar este.
    var name = base;
    for (var n = 2; groups.any((g) => g.name.toLowerCase() == name.toLowerCase()); n++) {
      name = '$base ($n)';
    }
    return saveGroup(name);
  }

  /// Desfaz o grupo. Os painéis continuam abertos e onde estavam: o que se
  /// desfaz é o laço entre eles, não o arranjo na tela.
  void ungroup(PaneGroup group) {
    _stamp(group, const []);
    groups.remove(group);
    _save();
    notifyListeners();
  }

  /// Marca [members] como os painéis de [group] -- e desmarca quem tinha a
  /// marca e não está mais na lista.
  ///
  /// Sempre pelo grupo inteiro, nunca painel por painel, porque é isso que a
  /// marca quer dizer: um grupo atualizado com dois painéis não pode deixar o
  /// terceiro colorido de um conjunto de que ele saiu.
  void _stamp(PaneGroup group, List<MxTab> members) {
    for (final t in tabs) {
      if (t.groupId == group.id && !members.contains(t)) t.groupId = null;
    }
    for (final t in members) {
      t.groupId = group.id;
    }
  }

  PaneGroup? groupById(String? id) =>
      id == null ? null : groups.firstWhereOrNull((g) => g.id == id);

  // --- programas ----------------------------------------------------------

  Launcher? launcherById(String? id) =>
      id == null ? null : launchers.firstWhereOrNull((l) => l.id == id);

  /// Ensina um programa novo e devolve ele -- é quem chamou que decide se abre
  /// um painel com ele em seguida.
  Launcher addLauncher({
    required String name,
    required String command,
    LauncherIcon icon = LauncherIcon.terminal,
  }) {
    final launcher = Launcher(
      // Do relógio e não do tamanho da lista: apagar dois e criar um terceiro
      // daria a ele o id de um painel salvo que apontava pro primeiro.
      id: 'lch${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      command: command.trim(),
      icon: icon,
    );
    launchers.add(launcher);
    _save();
    notifyListeners();
    return launcher;
  }

  /// Muda o que já existe, no lugar. Os painéis abertos seguram o programa por
  /// referência, então renomear já renomeia o cabeçalho deles -- e o comando
  /// novo é o que o próximo [relaunch] roda.
  void editLauncher(
    Launcher launcher, {
    String? name,
    String? command,
    LauncherIcon? icon,
  }) {
    final title = name?.trim();
    final run = command?.trim();
    if (title != null && title.isNotEmpty) launcher.name = title;
    if (run != null && run.isNotEmpty) launcher.command = run;
    if (icon != null) launcher.icon = icon;
    _save();
    notifyListeners();
  }

  /// Esquece o programa. Não fecha nada: os painéis dele viram os terminais
  /// que sempre foram por baixo, com o que estiver rodando dentro deles.
  void removeLauncher(Launcher launcher) {
    launchers.remove(launcher);
    for (final t in tabs.where((t) => t.launcher == launcher)) {
      t.launcher = null;
    }
    _save();
    notifyListeners();
  }

  /// Sobe de novo, no mesmo painel, o programa que já tinha saído.
  ///
  /// Um painel de programa é o programa: sair do `btop` deixa uma moldura com
  /// "processo saiu (0)" onde antes havia um monitor, e a resposta pra isso
  /// não é fechar o painel e refazer o caminho do menu. Só depois da saída --
  /// matar um processo vivo pra rodar o mesmo comando seria outro gesto, e um
  /// que ninguém pediu.
  void relaunch(MxTab tab) {
    final command = tab.launcher?.command;
    if (command == null || !tab.exited) return;
    tab.term.relaunch(command, tab.cwd);
    notifyListeners();
  }

  /// O grupo de que este painel faz parte, se faz de algum.
  PaneGroup? groupOf(MxTab tab) => groupById(tab.groupId);

  /// O grupo que a tela está mostrando, quando ela está mostrando um.
  ///
  /// Derivado e não guardado num campo: é verdade enquanto *todo* painel na
  /// tela for daquele grupo, e nada mais precisa se lembrar de apagar a
  /// resposta. Arrastar uma sessão de fora pra dentro da grade, ou trocar o
  /// conteúdo de um dos quadros, já responde não na jogada seguinte -- sem
  /// invalidação espalhada por [dismiss], [dropTab] e [closeTab].
  ///
  /// É o que separa a grade que veio de um grupo da grade que você montou à
  /// mão: só na primeira é que escolher uma sessão de fora desmancha a tela
  /// toda. Ver [select].
  PaneGroup? get activeGroup {
    final open = openPanes;
    if (open.isEmpty) return null;
    final group = groupOf(open.first);
    if (group == null) return null;
    return open.every((t) => t.groupId == group.id) ? group : null;
  }

  /// Se a tela é a do grupo. Ver [activeGroup].
  bool showing(PaneGroup group) => activeGroup?.id == group.id;

  void renameGroup(PaneGroup group, String name) {
    final title = name.trim();
    if (title.isEmpty || title == group.name) return;
    group.name = title;
    _save();
    notifyListeners();
  }

  /// Esquece o grupo. Não fecha nada: o grupo era uma forma de dispor painéis,
  /// e os painéis continuam abertos onde estavam.
  void removeGroup(PaneGroup group) {
    groups.remove(group);
    _save();
    notifyListeners();
  }

  /// Põe o arranjo do grupo na tela: os painéis dele, cortados como estavam.
  ///
  /// O que estava na tela e não está no grupo sai dela sem morrer, que é o que
  /// o x do cabeçalho faz -- ver [dismiss]. Clicar num grupo é trocar de
  /// vista, e clicar numa sessão da lateral continua sendo o que sempre foi:
  /// aquela sessão no lugar em foco.
  void openGroup(PaneGroup group) {
    // Suspende a gravação como faz a restauração da última execução: abrir
    // seis painéis seriam seis gravações do config, e a que interessa é a do
    // arranjo pronto, no fim.
    _restoring = true;
    final taken = <String>{};
    final panels = <MxTab?>[];
    for (final pane in group.panes) {
      final tab = _adopt(pane, taken) ?? _openPane(pane);
      // Uma posição por receita, com null onde nada abriu: as folhas da árvore
      // são índices desta lista. Ver [_restoreLayout].
      panels.add(tab);
      if (tab != null) taken.add(tab.id);
    }
    _restoring = false;

    final first = panels.nonNulls.firstOrNull;
    if (first == null) {
      showBanner('o grupo "${group.name}" não tem mais nenhum painel pra abrir');
      return;
    }
    panes =
        Panes.fromJson(group.tree, (i) => i >= 0 && i < panels.length ? panels[i]?.id : null) ??
        PaneLeaf(first.id);
    focusedPaneId = Panes.order(panes).firstOrNull;
    // Os painéis que entraram são os painéis do grupo, inclusive os que foram
    // abertos agora no lugar dos que morreram. É esta marca que faz a linha
    // deles compartilhar a cor e abrir o grupo em vez de trocar o quadro.
    _stamp(group, panels.nonNulls.toList());
    _save();
    notifyListeners();
  }

  /// O painel que já está aberto e serve pra esta vaga do grupo, se houver.
  ///
  /// Um grupo é um arranjo, não uma leva de sessões novas: os três terminais
  /// que você tirou da tela pra olhar outra coisa continuam vivos na lateral,
  /// e voltar ao grupo é trazer *eles* de volta. Subir três shells novos ao
  /// lado dos que já estavam ali seria acumular uma leva por clique -- é a
  /// mesma razão pela qual [showDoc] reaproveita o leitor aberto em vez de
  /// abrir o sexto painel.
  ///
  /// [taken] são as vagas já preenchidas: três terminais na mesma pasta são
  /// três receitas idênticas, e sem isso as três cairiam no mesmo painel.
  MxTab? _adopt(Map<String, dynamic> pane, Set<String> taken) {
    if (pane['kind'] == 'reader') {
      // Um leitor é *o* leitor, ver [showDoc]: o grupo não pede um painel de
      // leitura novo, pede que o que existe mostre este documento.
      final doc = MxDoc.fromJson(
        (pane['doc'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      );
      final reader = tabs.firstWhereOrNull((t) => t.isReader && !taken.contains(t.id));
      if (doc == null || reader == null) return null;
      reader.doc!.become(doc);
      // O apelido era o nome do documento anterior.
      reader.customLabel = null;
      return reader;
    }
    final root = pane['loose'] == true ? loose.root : pane['folderRoot'] as String?;
    final sessionId = pane['sessionId'] as String?;
    return tabs.firstWhereOrNull(
      (t) =>
          !taken.contains(t.id) &&
          t.kind.name == pane['kind'] &&
          t.folderRoot == root &&
          t.cwd == pane['cwd'] &&
          // Painel cujo processo saiu não é o painel de volta: o grupo abre um
          // no lugar dele -- e uma conversa do claude volta com `--resume`,
          // que é o arranjo de antes de verdade e não a casca dele.
          !t.exited &&
          // Com a conversa anotada na receita, é aquela conversa que o grupo
          // quer; sem ela, qualquer sessão viva naquela pasta serve.
          (sessionId == null || t.resumeId == sessionId),
    );
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

  /// Sair: encerrar toda sessão antes que a janela vá embora.
  ///
  /// Nenhum painel é filho deste processo de um jeito que o sistema vá
  /// recolher. Cada um é uma sessão de terminal própria (ver
  /// [TermSession.kill]), então ninguém desliga a linha por nós quando o app
  /// some -- e o que ficou aberto sobrevive a ele, invisível, até a máquina
  /// reiniciar. Desligar é conosco, e é a última coisa que ainda dá pra fazer.
  ///
  /// Diferente de [dispose], isto espera: é chamado de `onExitRequested`, que
  /// segura o encerramento até responder. O teto é a carência que cada sessão
  /// dá ao próprio hangup, com todas correndo em paralelo -- alguns segundos.
  Future<void> shutdown() async {
    // A gravação vem antes das mortes, não depois: [_writeConfig] só salva
    // painel que ainda roda, então um save que caísse depois dos hangups
    // restauraria uma janela vazia na próxima abertura.
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce!.cancel();
      await _writeConfig();
    }
    agents.stop();
    await hooks.stop();
    await Future.wait([for (final t in tabs) _end(t)]);
  }

  /// Cancela o que a sessão ainda ia fazer e desliga a linha.
  Future<void> _end(MxTab tab) {
    tab.pendingFollowUp?.cancel();
    return tab.term.kill();
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
      // Nada de await aqui: este é o caminho sem futuro nenhum pra rodar
      // depois dele. O hangup sai; quem escala é [shutdown].
      t.term.hangUp();
    }
    super.dispose();
  }
}
