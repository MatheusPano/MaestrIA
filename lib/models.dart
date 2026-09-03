import 'theme.dart';
import 'package:flutter/material.dart';

/// A repo the user works in. Worktrees of the same repo group under one folder.
class Folder {
  Folder({required this.root, required this.name, this.collapsed = false}) : isLoose = false;

  /// The one folder that is not a folder: the tray panels hang from when
  /// they belong to no repo at all. There is exactly one, it is never written
  /// to the config, and git never looks at it — a session you opened just to
  /// ask something is not a checkout. Its [root] is only the folder a panel
  /// starts in when you do not pick one.
  Folder.loose(this.root) : name = 'avulsos', isLoose = true, collapsed = false;

  /// Main checkout path. Also the identity: worktrees resolve back to it.
  final String root;
  String name;
  bool collapsed;

  /// See [Folder.loose]. Everything git-shaped in the UI asks this first.
  final bool isLoose;

  /// Filled in by `AppStore.refreshGit` from `git worktree list`: whether the
  /// folder turned out to be a repo at all, and what the main checkout is on.
  bool isRepo = false;
  String branch = '';

  Map<String, dynamic> toJson() => {'root': root, 'name': name, 'collapsed': collapsed};

  static Folder fromJson(Map<String, dynamic> j) => Folder(
    root: j['root'] as String,
    name: j['name'] as String,
    collapsed: (j['collapsed'] as bool?) ?? false,
  );
}

/// A named piece of work inside a folder: "permissão do google", not
/// `learning-app-lms`.
///
/// It lives only here. No branch, no directory, nothing written into the repo
/// — git has no opinion about why four of these panels are open at the same
/// time, and that "why" is the one thing the sidebar could not say. A folder
/// answers *where* a session runs; a project answers *what for*, which is also
/// the scope in which handing work from one agent to the next makes any sense.
class Project {
  Project({
    required this.id,
    required this.folderRoot,
    required this.name,
    this.brief = '',
    this.collapsed = false,
  });

  /// Stable across renames, because panels point at it and the config file
  /// has to survive you calling it something else tomorrow.
  final String id;

  /// The folder it hangs under. A project never spans two repos: the panels
  /// in it would have nothing to hand each other.
  ///
  /// Também é [Folder.loose]`.root` pro projeto da bandeja dos avulsos, que é
  /// o que a lateral e a store já fazem com os painéis de lá -- um trabalho
  /// com nome que não mora em repo nenhum ainda é um trabalho com nome. É a
  /// raiz porque é assim que tudo aqui se pergunta "de que lugar é isto":
  /// ver `AppStore.projectsOf` e `AppStore.assign`.
  final String folderRoot;
  String name;

  /// The standing context every Claude session started in here is launched
  /// with, as `--append-system-prompt`.
  ///
  /// This is the paragraph you would otherwise retype into each of the four
  /// panels — which api, which decision was already made, what not to touch.
  /// In the system prompt it survives the whole session instead of scrolling
  /// out of the conversation.
  String brief;

  bool collapsed;

  Map<String, dynamic> toJson() => {
    'id': id,
    'folderRoot': folderRoot,
    'name': name,
    'brief': brief,
    'collapsed': collapsed,
  };

  static Project fromJson(Map<String, dynamic> j) => Project(
    id: j['id'] as String,
    folderRoot: j['folderRoot'] as String,
    name: j['name'] as String,
    brief: (j['brief'] as String?) ?? '',
    collapsed: (j['collapsed'] as bool?) ?? false,
  );
}

/// Um arranjo de painéis salvo com nome: a grade de três terminais que você
/// monta toda manhã, guardada pra voltar num clique.
///
/// O que ele guarda é a receita do arranjo -- quais painéis, em que pasta, como
/// cortados e em que proporção --, que é exatamente o que o layout salvo entre
/// duas execuções do app já guardava (ver `AppStore._writeConfig`). A diferença
/// é o número: o layout é um só e é o de agora; destes cabem vários, cada um
/// com nome, e trocar de um pro outro é uma linha na lateral.
///
/// Não é um projeto e não é uma pasta. Um projeto diz *para quê* as sessões
/// existem e as sessões ficam nele; um grupo não é dono de nada -- é uma forma
/// de dispor na tela painéis que continuam sendo dos seus projetos e das suas
/// pastas. É por isso que ele não mora dentro de uma pasta: um grid com um
/// claude num repo e um terminal noutro é um arranjo legítimo, e pendurá-lo em
/// uma das duas pastas seria mentira.
class PaneGroup {
  PaneGroup({required this.id, required this.name, required this.panes, this.tree});

  /// Estável entre execuções, e não o contador de painéis: `tab3` nomearia um
  /// grupo diferente a cada vez que o app abrisse.
  final String id;
  String name;

  /// Uma receita por painel, na ordem em que eles apareciam na tela. Ver
  /// `MxTab.recipe`: é o mesmo json de um painel do layout salvo, menos o que
  /// aconteceu dentro dele.
  final List<Map<String, dynamic>> panes;

  /// Os cortes, do jeito que `Panes.toJson` escreve. As folhas são índices
  /// desta lista [panes] e não ids de sessão -- um id não sobrevive ao
  /// fechamento da janela, e um grupo tem que sobreviver a ele.
  ///
  /// Null é um arranjo de um painel só: não há corte pra guardar.
  final Object? tree;

  /// Quantos painéis o grupo abre.
  int get count => panes.length;

  /// O que a linha do grupo diz embaixo do nome: o que ele abre, contado.
  ///
  /// Vem das receitas e não de um campo salvo porque é derivado -- um resumo
  /// gravado no config seria a mesma informação numa segunda cópia, livre pra
  /// divergir da primeira.
  String get summary => summarize(panes);

  /// O mesmo resumo, antes de existir grupo: é com ele que um grupo salvo pelo
  /// menu do painel se batiza, já que ali ninguém digita nome nenhum. Ver
  /// `AppStore.groupPanes`.
  static String summarize(List<Map<String, dynamic>> panes) {
    final claude = panes.where((p) => p['kind'] == 'claude').length;
    final shell = panes.where((p) => p['kind'] == 'shell').length;
    final reader = panes.where((p) => p['kind'] == 'reader').length;
    final parts = [
      if (claude > 0) claude == 1 ? 'uma sessão' : '$claude sessões',
      if (shell > 0) shell == 1 ? 'um terminal' : '$shell terminais',
      if (reader > 0) reader == 1 ? 'um leitor' : '$reader leitores',
    ];
    if (parts.isEmpty) return '';
    if (parts.length == 1) return parts.first;
    return '${parts.take(parts.length - 1).join(', ')} e ${parts.last}';
  }

  /// Onde os painéis dele rodam, sem repetir pasta.
  ///
  /// É o que a linha do grupo diz embaixo do nome quando o nome *é* o resumo
  /// -- um grupo salvo pelo botão direito se chama "3 terminais", e "3
  /// terminais" outra vez embaixo seria a linha se repetindo. Ver `_GroupRow`.
  String get where {
    final seen = <String>[];
    for (final p in panes) {
      final root = p['loose'] == true ? 'avulsos' : (p['folderRoot'] as String? ?? '');
      final parts = root.split('/')..removeWhere((s) => s.isEmpty);
      final name = parts.isEmpty ? '' : parts.last;
      if (name.isNotEmpty && !seen.contains(name)) seen.add(name);
    }
    return seen.join(' · ');
  }

  /// A cor do grupo: a mesma em todas as linhas dele, e a mesma amanhã.
  ///
  /// Tirada do [id], que é o que está salvo no config -- e por soma de
  /// caracteres, não por `hashCode`, que a linguagem não promete igual entre
  /// duas execuções. Não é a posição na lista de propósito: apagar o primeiro
  /// grupo repintaria todos os outros.
  Color get color {
    final tints = Mx.groupTints;
    final sum = id.codeUnits.fold<int>(0, (a, b) => a + b);
    return tints[sum % tints.length];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'panes': panes,
    if (tree != null) 'tree': tree,
  };

  /// Devolve null pro registro que não abriria nada -- sem nome, sem id ou sem
  /// painel. Nulo e não exceção porque quem lê é o carregador do config
  /// inteiro: um grupo estragado não pode custar as pastas e o layout.
  static PaneGroup? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = (j['id'] as String?) ?? '';
    final name = ((j['name'] as String?) ?? '').trim();
    final panes = (j['panes'] as List? ?? const [])
        .whereType<Map>()
        .map((p) => p.cast<String, dynamic>())
        .toList();
    if (id.isEmpty || name.isEmpty || panes.isEmpty) return null;
    return PaneGroup(id: id, name: name, panes: panes, tree: j['tree']);
  }
}

/// What a panel does the next time its session goes quiet.
enum FollowUpKind {
  /// Types the text back into the same session. The next step of a plan you
  /// already knew you wanted taken.
  keepGoing,

  /// Starts a fresh session in the same folder, with the text as its first
  /// prompt. Fresh is the point for a review: it reads the diff, not the
  /// reasoning that produced it.
  newSession,

  /// A shell panel running the text as a command.
  command,

  /// Hands this panel's closing message to another panel, and the text with
  /// it. The one that makes two agents a pair instead of two windows.
  handoff,
}

extension FollowUpKindUi on FollowUpKind {
  String get label => switch (this) {
    FollowUpKind.keepGoing => 'continuar aqui',
    FollowUpKind.newSession => 'abrir outra sessão',
    FollowUpKind.command => 'rodar um comando',
    FollowUpKind.handoff => 'passar pra outro painel',
  };

  IconData get icon => switch (this) {
    FollowUpKind.keepGoing => Icons.subdirectory_arrow_right,
    FollowUpKind.newSession => Icons.add_comment_outlined,
    FollowUpKind.command => Icons.terminal,
    FollowUpKind.handoff => Icons.swap_horiz,
  };
}

/// One step of a panel's queue. See [FollowUpKind].
class FollowUp {
  FollowUp({required this.kind, required this.text, this.targetTabId});

  final FollowUpKind kind;
  final String text;

  /// Only [FollowUpKind.handoff] uses it. A panel that has since been closed
  /// makes the step a no-op — a dead target is not worth an error dialog.
  final String? targetTabId;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    if (targetTabId != null) 'target': targetTabId,
  };

  static FollowUp? fromJson(Map<String, dynamic> j) {
    final kind = FollowUpKind.values.asNameMap()[j['kind'] as String? ?? ''];
    if (kind == null) return null;
    return FollowUp(
      kind: kind,
      text: (j['text'] as String?) ?? '',
      targetTabId: j['target'] as String?,
    );
  }
}

class WorktreeInfo {
  WorktreeInfo({
    required this.path,
    required this.branch,
    required this.isMain,
    this.prunable = false,
  });
  final String path;
  final String branch;
  final bool isMain;

  /// git's own word for a worktree whose folder is gone: the registration
  /// survives, the checkout does not. Starting anything in one of these is
  /// starting it nowhere, so the UI offers to clear it instead of to open it.
  final bool prunable;

  /// `feature/TASK#47730` -> `TASK#47730`; `.claude/worktrees/TASK-47730` -> `TASK-47730`.
  String get shortLabel {
    final m = RegExp(r'([A-Z]+[#-]?\d+)').firstMatch(branch);
    if (m != null) return m.group(1)!;
    final b = branch.split('/').last;
    return b.isEmpty ? path.split('/').last : b;
  }
}

/// What a Claude session is doing right now, as told by its hooks.
enum ClaudeStatus {
  unknown,

  /// Launched, still painting its prompt. A couple of seconds, no more —
  /// [HookState.settle] is what gets a panel out of here.
  starting,

  /// Up, and nothing has happened yet: the cursor is blinking at you. Told
  /// apart from [idle] because a session that has never run a turn has not
  /// *finished* anything, and a tick over the mark would say it had.
  ready,

  working,
  tool,
  waitingInput,

  /// Parked on an `AskUserQuestion`: the session wrote a question and holds
  /// the turn until you pick one of the answers it offered.
  ///
  /// Its own state because a question and a permission prompt ask for
  /// different things, and the sidebar has to say which. A permission prompt
  /// asks you to *authorise* something the session wants to do; saying yes is
  /// the risk, which is what earns the red lock. A question authorises
  /// nothing — it is the session handing a decision back to you. Rendered as
  /// [waitingPermission] it came out as "quer aprovação pra
  /// AskUserQuestion": a red gate over a session that was only waiting to be
  /// answered, and the internal tool name in place of what was asked.
  waitingAnswer,

  waitingPermission,
  idle,
  ended,
}

extension ClaudeStatusUi on ClaudeStatus {
  String get label => switch (this) {
    ClaudeStatus.unknown => '—',
    ClaudeStatus.starting => 'abrindo',
    ClaudeStatus.ready => 'pronto',
    ClaudeStatus.working => 'pensando',
    ClaudeStatus.tool => 'rodando',
    ClaudeStatus.waitingInput => 'esperando você',
    ClaudeStatus.waitingAnswer => 'pergunta',
    ClaudeStatus.waitingPermission => 'permissão',
    ClaudeStatus.idle => 'ocioso',
    ClaudeStatus.ended => 'encerrada',
  };

  Color get color => switch (this) {
    ClaudeStatus.working || ClaudeStatus.tool => Mx.accent,
    // Yellow with [waitingInput], not red: both are the session waiting on
    // you with nothing at stake but your attention. Red is reserved for the
    // one state where the answer lets something happen to the repo.
    ClaudeStatus.waitingInput || ClaudeStatus.waitingAnswer => Mx.yellow,
    ClaudeStatus.waitingPermission => Mx.red,
    ClaudeStatus.idle || ClaudeStatus.ready => Mx.green,
    ClaudeStatus.starting => Mx.purple,
    _ => Mx.fgFaint,
  };

  /// Does this state want the human? That is what earns a badge in the sidebar.
  bool get needsHuman =>
      this == ClaudeStatus.waitingInput ||
      this == ClaudeStatus.waitingAnswer ||
      this == ClaudeStatus.waitingPermission;

  /// What the session wants from you, for a line that has no room to explain:
  /// the dock notification, and the count under a project.
  String get callToAction => switch (this) {
    ClaudeStatus.waitingPermission => 'quer aprovação',
    ClaudeStatus.waitingAnswer => 'te faz uma pergunta',
    _ => 'te espera',
  };
}

/// Um plano que a sessão escreveu, do jeito que ela escreveu.
///
/// O `ExitPlanMode` carrega o plano inteiro em markdown no `tool_input`, e o
/// hook já passava por aqui — o texto estava sendo jogado fora. É o documento
/// mais lido de uma sessão e o único que não existia em lugar nenhum: no
/// terminal ele é uma parede de texto que rola pra fora da tela, e no disco
/// ele não está.
class PlanNote {
  PlanNote({required this.text, DateTime? at}) : at = at ?? DateTime.now();

  final String text;
  final DateTime at;

  /// A primeira linha de cabeçalho do plano, ou a primeira linha que tenha
  /// alguma coisa: é como o plano se chama numa ficha de 200px.
  String get headline {
    for (final line in text.split('\n')) {
      final one = line.trim().replaceAll(RegExp(r'^#+\s*'), '');
      if (one.isNotEmpty) return one.length <= 70 ? one : '${one.substring(0, 70)}…';
    }
    return 'plano sem título';
  }

  Map<String, dynamic> toJson() => {'text': text, 'at': at.toIso8601String()};

  static PlanNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final text = j['text'] as String?;
    if (text == null || text.trim().isEmpty) return null;
    return PlanNote(text: text, at: DateTime.tryParse(j['at'] as String? ?? ''));
  }
}

/// Live state of one Claude session, accumulated from hook events.
class HookState {
  ClaudeStatus status = ClaudeStatus.starting;
  String? sessionId;
  String? permissionMode;
  String? activeTool;
  DateTime? toolStartedAt;
  String? lastToolTarget;
  String? lastMessage;

  /// What the session is asking, while it is parked on an `AskUserQuestion`:
  /// the short header the question was filed under if it has one, the
  /// question itself otherwise. Null the rest of the time.
  ///
  /// The point of [ClaudeStatus.waitingAnswer] is that the row can say what
  /// the decision is about, and only the tool call knows that -- by the time
  /// the prompt is on screen the sidebar has nothing but a tool name.
  String? question;

  /// How many questions that one call carries. `AskUserQuestion` may ask up
  /// to four at once, and answering is one interaction, not four -- so the
  /// row names the first and counts the rest.
  int questions = 0;

  /// The same message, unclipped. [lastMessage] is cut to 90 characters
  /// because it is a subtitle; a handoff has to carry what was actually said.
  String? lastMessageFull;
  String? lastPrompt;
  int prompts = 0;
  int tools = 0;
  DateTime? lastEventAt;

  /// The files this session wrote to, in the order it first touched them.
  ///
  /// The product of the work. Until this existed it lived only in the
  /// scrollback, which is to say it lived nowhere the moment the session
  /// scrolled — a panel could spend an hour rewriting six files and have
  /// nothing to show for it but a wall of tool calls.
  ///
  /// Reads are deliberately absent. A session that reads forty files to
  /// change three would list forty-three, and the three are the answer.
  final List<String> touched = [];

  /// Oldest paths are dropped past this. A session long enough to hit it has
  /// long since stopped being a list you read top to bottom, and an unbounded
  /// list is a leak the config file would have to carry too.
  static const maxTouched = 200;

  /// Os planos que esta sessão escreveu, na ordem em que escreveu. Ver
  /// [PlanNote].
  ///
  /// Uma lista e não o último: um turno longo replaneja, e o plano anterior é
  /// justamente o que se quer reler pra saber o que mudou.
  final List<PlanNote> plans = [];

  /// Poucos de propósito. Um plano tem quilobytes, não bytes, e a décima
  /// versão dele não é mais material de leitura — é histórico.
  static const maxPlans = 8;

  /// O plano da vez, que é o que o cabeçalho do painel oferece.
  PlanNote? get plan => plans.isEmpty ? null : plans.last;

  /// The session came up and has nothing to report. Answers false when the
  /// panel had already moved on, so a late caller cannot walk a working
  /// session back to the prompt.
  ///
  /// A panel needs this because nothing announces the prompt: Claude Code does
  /// not deliver `SessionStart` to `http` hooks, so the first event a fresh
  /// panel ever sees is the `UserPromptSubmit` of whatever you type. Until it
  /// existed, a session you had just opened spun "subindo" for as long as you
  /// looked at it — a working spinner over a process that was sitting still.
  bool settle() {
    if (status != ClaudeStatus.starting) return false;
    status = ClaudeStatus.ready;
    return true;
  }

  /// The one-line subtitle a panel shows under its title.
  String get subtitle {
    if (status == ClaudeStatus.waitingPermission) return 'quer aprovação pra $activeTool';
    if (status == ClaudeStatus.waitingAnswer) {
      final rest = questions > 1 ? ' (+${questions - 1})' : '';
      return question == null ? 'te faz uma pergunta' : 'pergunta: $question$rest';
    }
    if (status == ClaudeStatus.waitingInput) return lastMessage ?? 'te espera';
    if (status == ClaudeStatus.tool && activeTool != null) {
      final secs = toolStartedAt == null
          ? ''
          : ' ${DateTime.now().difference(toolStartedAt!).inSeconds}s';
      final target = lastToolTarget == null ? '' : '(${lastToolTarget!})';
      return '$activeTool$target$secs';
    }
    if (status == ClaudeStatus.working) return lastPrompt ?? 'trabalhando';
    if (status == ClaudeStatus.idle) return lastMessage ?? 'pronto';
    return status.label;
  }
}

/// One row of `claude agents --json`.
class AgentInfo {
  AgentInfo({
    required this.pid,
    required this.cwd,
    required this.kind,
    this.sessionId,
    this.name,
    this.status,
    this.waitingFor,
    this.state,
    this.startedAt,
  });

  final int? pid;
  final String cwd;
  final String kind;
  final String? sessionId;
  final String? name;
  final String? status;
  final String? waitingFor;
  final String? state;

  /// Epoch millis, as the CLI reports it.
  final int? startedAt;

  static AgentInfo fromJson(Map<String, dynamic> j) => AgentInfo(
    pid: j['pid'] as int?,
    cwd: (j['cwd'] as String?) ?? '',
    kind: (j['kind'] as String?) ?? 'interactive',
    sessionId: j['sessionId'] as String?,
    name: j['name'] as String?,
    status: j['status'] as String?,
    waitingFor: j['waitingFor'] as String?,
    state: j['state'] as String?,
    startedAt: (j['startedAt'] as num?)?.toInt(),
  );
}

/// O desenho de um [Launcher] na lateral e no menu do +.
///
/// Uma lista fechada e não um emoji digitado: o que identifica um programa numa
/// linha de 26px é a silhueta, e um conjunto pequeno de silhuetas desenhadas
/// pela mesma mão é o que faz a lateral continuar legível com seis deles. O
/// [name] é o que vai pro config -- um codepoint de ícone não é estável entre
/// versões do Flutter, e o dia em que ele mudasse os programas de todo mundo
/// viriam com o desenho errado.
enum LauncherIcon {
  terminal('terminal', Icons.terminal),
  monitor('monitor', Icons.monitor_heart_outlined),
  chart('gráfico', Icons.bar_chart),
  git('git', Icons.call_split),
  server('servidor', Icons.dns_outlined),
  database('banco', Icons.storage_outlined),
  rocket('foguete', Icons.rocket_launch_outlined),
  bug('bug', Icons.bug_report_outlined),
  edit('editor', Icons.edit_outlined),
  box('caixa', Icons.inventory_2_outlined);

  const LauncherIcon(this.label, this.glyph);
  final String label;
  final IconData glyph;

  static LauncherIcon byName(String? name) =>
      values.asNameMap()[name ?? ''] ?? LauncherIcon.terminal;
}

/// Um programa que o usuário ensinou ao maestria: um nome, um comando e um
/// desenho.
///
/// É a generalização do que "sessão do claude" e "terminal" sempre foram. O
/// claude nunca foi um tipo de painel de verdade -- é um terminal que já sobe
/// com um comando digitado --, e a única coisa que o separava de `btop` era
/// estar escrito no código. Isto é o mesmo mecanismo com o comando vindo do
/// config: `btop` vira uma linha do menu do +, abre direto no programa e volta
/// assim depois de fechar a janela.
///
/// Não é um atalho de teclado ([MxAction]) e não é um grupo ([PaneGroup]): um
/// grupo guarda um arranjo de painéis que já existem, este guarda como *abrir*
/// um. Quatro painéis de `btop` são quatro painéis do mesmo programa.
class Launcher {
  Launcher({
    required this.id,
    required this.name,
    required this.command,
    this.icon = LauncherIcon.terminal,
  });

  /// Estável entre execuções: os painéis salvos apontam pra cá, e renomear o
  /// programa não pode fazê-los voltar como terminais quaisquer.
  final String id;

  /// Como ele se chama no menu, e como o painel dele se chama na lateral.
  String name;

  /// O que roda no pty, do jeito que você digitaria no terminal --
  /// `btop`, `lazygit`, `npm run dev`. Vai pro shell de login como está, então
  /// pipe, aspas e `&&` valem.
  String command;

  LauncherIcon icon;

  /// A cor do ícone dele, a mesma hoje e amanhã. Mesma conta de
  /// [PaneGroup.color], e pelo mesmo motivo: sai do [id] salvo, e não da
  /// posição na lista -- apagar o primeiro programa repintaria todos os
  /// outros.
  Color get color {
    final tints = Mx.groupTints;
    final sum = id.codeUnits.fold<int>(0, (a, b) => a + b);
    return tints[sum % tints.length];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'command': command,
    'icon': icon.name,
  };

  /// Null pro registro que não abriria nada -- sem id, sem nome ou sem
  /// comando. Nulo e não exceção pelo mesmo motivo de [PaneGroup.fromJson]:
  /// quem lê é o carregador do config inteiro, e um programa estragado não
  /// pode custar as pastas e o layout.
  static Launcher? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = (j['id'] as String?) ?? '';
    final name = ((j['name'] as String?) ?? '').trim();
    final command = ((j['command'] as String?) ?? '').trim();
    if (id.isEmpty || name.isEmpty || command.isEmpty) return null;
    return Launcher(
      id: id,
      name: name,
      command: command,
      icon: LauncherIcon.byName(j['icon'] as String?),
    );
  }
}
