import 'theme.dart';
import 'package:flutter/material.dart';

/// A repo the user works in. Worktrees of the same repo group under one folder.
class Folder {
  Folder({
    required this.root,
    required this.name,
    this.collapsed = false,
    this.worktreesCollapsed = true,
  }) : isLoose = false;

  /// The one folder that is not a folder: the tray panels hang from when
  /// they belong to no repo at all. There is exactly one, it is never written
  /// to the config, and git never looks at it — a session you opened just to
  /// ask something is not a checkout. Its [root] is only the folder a panel
  /// starts in when you do not pick one.
  Folder.loose(this.root)
    : name = 'avulsos',
      isLoose = true,
      collapsed = false,
      worktreesCollapsed = true;

  /// Main checkout path. Also the identity: worktrees resolve back to it.
  final String root;
  String name;
  bool collapsed;

  /// The worktree folder starts folded, and both fold states are remembered.
  /// A list of five branches you are not working on right now is reference
  /// material, not the point of the sidebar.
  bool worktreesCollapsed;

  /// See [Folder.loose]. Everything git-shaped in the UI asks this first.
  final bool isLoose;

  /// Filled in by `AppStore.refreshGit` from `git worktree list`: whether the
  /// folder turned out to be a repo at all, and what the main checkout is on.
  bool isRepo = false;
  String branch = '';

  Map<String, dynamic> toJson() => {
    'root': root,
    'name': name,
    'collapsed': collapsed,
    'worktreesCollapsed': worktreesCollapsed,
  };

  static Folder fromJson(Map<String, dynamic> j) => Folder(
    root: j['root'] as String,
    name: j['name'] as String,
    collapsed: (j['collapsed'] as bool?) ?? false,
    worktreesCollapsed: (j['worktreesCollapsed'] as bool?) ?? true,
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

/// An `Agent` tool call the panel's Claude spawned: one fork, one row.
///
/// Hooks name a subagent in two halves that never arrive together. The
/// parent's `PreToolUse` on the `Agent` tool carries what the work *is* --
/// the description Claude wrote for it -- and the `SubagentStart` that
/// follows carries the `agent_id` every event the child will ever be stamped
/// with. The panel holds the first half until the second shows up; the
/// `Agent` call's own `PostToolUse` later confirms the pairing by id and
/// closes the row with what it cost.
class SubagentState {
  SubagentState({required this.agentId, required this.agentType});

  final String agentId;
  String agentType;

  /// Claude's own one-line description of the errand. Empty until the
  /// `SubagentStart` is paired with the `Agent` call that asked for it.
  String description = '';

  /// The brief it was actually sent, as written in the `Agent` call. The one
  /// thing a row cannot show and the only honest answer to "o que ele foi
  /// fazer" -- the description is a label, this is the instruction.
  String prompt = '';

  /// Launched with `run_in_background`, so the session went back to the
  /// prompt instead of blocking on it. The case the sidebar could not say
  /// anything about at all: a panel reading "ocioso" over two live forks.
  bool background = false;

  ClaudeStatus status = ClaudeStatus.working;
  String? activeTool;
  String? lastToolTarget;
  DateTime? toolStartedAt;
  final DateTime startedAt = DateTime.now();
  DateTime? endedAt;
  String? lastMessage;

  /// The same closing message, unclipped, for the detail sheet. [lastMessage]
  /// is a subtitle; this is what the fork actually reported back.
  String? lastMessageFull;
  int tools = 0;

  /// What the errand cost, as the `Agent` tool reports it on the way out.
  /// Null while it runs, and null for a background agent whose `PostToolUse`
  /// returned the moment it was launched.
  int? tokens;
  int? durationMs;

  /// The tools it has called, newest last. Where a fork *is*, in the only
  /// terms a panel has: a row can show the one it is on, this shows the path
  /// it took to get there.
  final List<String> trail = [];
  static const maxTrail = 14;

  bool get running => endedAt == null;

  /// Short enough to read, long enough to grep the transcript with.
  String get shortId => agentId.length > 8 ? agentId.substring(0, 8) : agentId;

  Duration get elapsed => durationMs != null && durationMs! > 0
      ? Duration(milliseconds: durationMs!)
      : (endedAt ?? DateTime.now()).difference(startedAt);

  /// The description if there is one -- a fork is remembered by its errand,
  /// not by the pool it came from. The id is the last resort and never
  /// reached in practice; a row with no name at all is not a row, it is a
  /// bug wearing one.
  String get title {
    if (description.isNotEmpty) return description;
    if (agentType.isNotEmpty) return agentType;
    return 'subagente $shortId';
  }

  String get subtitle {
    final parts = <String>[if (agentType.isNotEmpty) agentType];
    if (running && activeTool != null) {
      final target = lastToolTarget == null ? '' : '(${lastToolTarget!})';
      parts.add('$activeTool$target');
    }
    parts.add(_elapsed(elapsed));
    if (!running && tokens != null) parts.add('${_thousands(tokens!)} tokens');
    return parts.join(' · ');
  }

  /// One tool call, recorded as it starts. See [trail].
  void note(String call) {
    trail.add(call);
    if (trail.length > maxTrail) trail.removeAt(0);
  }

  /// The row's colour: a finished fork is history, whatever it was doing.
  ClaudeStatus get shownStatus => running ? status : ClaudeStatus.idle;

  static String elapsedLabel(Duration d) => _elapsed(d);

  static String _elapsed(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes}m${d.inSeconds % 60}s' : '${d.inSeconds}s';

  static String _thousands(int n) {
    if (n < 1000) return '$n';
    final k = n / 1000;
    return k >= 100 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }
}

/// An `Agent` call seen going out, still waiting for the `SubagentStart` that
/// will give it an id. See [SubagentState].
class PendingAgent {
  PendingAgent({
    required this.description,
    required this.agentType,
    required this.prompt,
    required this.background,
  });
  final String description;
  final String agentType;
  final String prompt;
  final bool background;
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

  /// The forks this session has going, newest last, keyed by `agent_id`.
  ///
  /// Finished ones stay until the next prompt: "terminou em 48s" is the
  /// answer to what the last turn did, and it is gone from the scrollback by
  /// the time you look. Not persisted -- a subagent belongs to the turn that
  /// spawned it, and no restored panel has one still running.
  final Map<String, SubagentState> subagents = {};

  /// `Agent` calls seen going out, not yet matched to a `SubagentStart`.
  final List<PendingAgent> pendingAgents = [];

  Iterable<SubagentState> get liveSubagents => subagents.values.where((a) => a.running);

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
    // A session with forks out is doing exactly one thing worth naming, and
    // it is not the `Agent` tool call it is parked on. This also covers the
    // background case, where the session is back at the prompt -- `idle` --
    // while the work it asked for is still running.
    final live = liveSubagents.length;
    if (live > 0) return live == 1 ? '1 agente rodando' : '$live agentes rodando';
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
