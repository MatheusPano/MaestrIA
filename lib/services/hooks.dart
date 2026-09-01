import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';

class HookEvent {
  HookEvent(this.tabId, this.name, this.payload);
  final String tabId;
  final String name;
  final Map<String, dynamic> payload;
}

/// A loopback HTTP server that Claude Code's hooks report into.
///
/// This is the whole trick behind live panel titles. The alternative -- tailing
/// the transcript JSONL -- reads an explicitly internal format that changes
/// between releases; hooks are a documented contract, and the `http` handler
/// type means no wrapper scripts on disk.
class HookServer {
  HttpServer? _server;
  final _controller = StreamController<HookEvent>.broadcast();

  Stream<HookEvent> get events => _controller.stream;
  int get port => _server?.port ?? 0;
  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      // /hook/<tabId> -- the tab is in the URL because a session id only
      // arrives with the first event, and panels need a home before that.
      final segments = req.uri.pathSegments;
      final tabId = segments.length >= 2 ? segments[1] : '';
      try {
        final body = await utf8.decoder.bind(req).join();
        final payload = body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(body) as Map<String, dynamic>;
        final name = (payload['hook_event_name'] as String?) ?? '';
        if (tabId.isNotEmpty && name.isNotEmpty) {
          _controller.add(HookEvent(tabId, name, payload));
        }
      } catch (_) {
        // A malformed body must never stall the session that sent it.
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        // An empty decision: we observe, we never rule on a tool call.
        ..write('{}');
      await req.response.close();
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// The `--settings` payload for one tab.
  ///
  /// `--settings` merges over the user's own settings files instead of
  /// replacing them, so this adds our listeners and touches nothing else --
  /// no writing to ~/.claude/settings.json. A short timeout matters: if the
  /// cockpit is closed mid-session, a blocking hook must fail fast, not hang
  /// the session for the default ten minutes.
  String settingsFor(String tabId) {
    final url = 'http://127.0.0.1:$port/hook/$tabId';
    Map<String, dynamic> group({String? matcher}) => {
      if (matcher != null) 'matcher': matcher,
      'hooks': [
        {'type': 'http', 'url': url, 'timeout': 5},
      ],
    };
    return jsonEncode({
      'hooks': {
        'SessionStart': [group()],
        'SessionEnd': [group()],
        'UserPromptSubmit': [group()],
        'PreToolUse': [group(matcher: '*')],
        'PostToolUse': [group(matcher: '*')],
        // The two halves of a fork's life. Unlike `SessionStart`, both of
        // these do reach an `http` hook -- verified against 2.1.251 -- and
        // they are the only place an `agent_id` is announced before the
        // child's first tool call carries it.
        'SubagentStart': [group()],
        'SubagentStop': [group()],
        'Notification': [group()],
        'Stop': [group()],
      },
    });
  }
}

/// Hook events -> panel state. Pure, so it is the part worth testing.
class HookReducer {
  static void apply(HookState s, String event, Map<String, dynamic> p) {
    s.lastEventAt = DateTime.now();
    s.sessionId = (p['session_id'] as String?) ?? s.sessionId;
    s.permissionMode = (p['permission_mode'] as String?) ?? s.permissionMode;

    // Everything a subagent fires reaches the parent's hook, on the parent's
    // tab, stamped with an `agent_id` -- the documented way to tell the two
    // apart. Without this branch a fork's `Grep` was indistinguishable from
    // the panel's own work: the row read "rodando Grep(store.dart)" while the
    // session itself was parked on the `Agent` call, and files four forks
    // wrote all landed on one timeline.
    final agentId = p['agent_id'] as String?;
    if (agentId != null) {
      _subagent(s, agentId, event, p);
      return;
    }

    switch (event) {
      case 'SessionStart':
        // Kept for the day it starts arriving: Claude Code does not fire this
        // one at an `http` hook today, which is why a panel settles itself.
        s.status = ClaudeStatus.ready;
      case 'UserPromptSubmit':
        // A finished fork is the answer to the last turn, not this one.
        s.subagents.removeWhere((_, a) => !a.running);
        // Answering a question submits a prompt, and so does abandoning it:
        // either way what was asked is no longer pending.
        s.question = null;
        s.questions = 0;
        s.prompts++;
        s.status = ClaudeStatus.working;
        s.lastPrompt = _clip(p['user_input'] as String?, 70);
      case 'PreToolUse':
        if (p['tool_name'] == 'Agent') _agentQueued(s, p['tool_input']);
        if (p['tool_name'] == _askTool) _asked(s, p['tool_input']);
        s.tools++;
        // `AskUserQuestion` is the one tool whose whole job is to stop: the
        // call itself means the turn is now waiting on a human, so the row
        // says so from the call rather than from the prompt that follows it.
        // Waiting for the `Notification` left a window -- a couple of hundred
        // milliseconds, longer under a slow hook, and forever in the modes
        // that never prompt -- where the sidebar showed a working spinner
        // over "AskUserQuestion 4s".
        s.status = p['tool_name'] == _askTool ? ClaudeStatus.waitingAnswer : ClaudeStatus.tool;
        s.activeTool = p['tool_name'] as String?;
        s.toolStartedAt = DateTime.now();
        s.lastToolTarget = _target(p['tool_input']);
      case 'PostToolUse':
        if (p['tool_name'] == 'Agent') _agentReturned(s, p);
        s.status = ClaudeStatus.working;
        s.activeTool = null;
        s.toolStartedAt = null;
        s.question = null;
        s.questions = 0;
        _touch(s, p);
      case 'Notification':
        final type = (p['notification_type'] as String?) ?? '';
        if (type == 'permission_prompt') {
          // A question is approved through the same prompt machinery as a
          // tool call, so this event fires for it too -- and taking it at
          // face value is what put a red lock and "quer aprovação pra
          // AskUserQuestion" on a session that had merely asked something.
          s.status = s.activeTool == _askTool
              ? ClaudeStatus.waitingAnswer
              : ClaudeStatus.waitingPermission;
        } else if (type == 'agent_needs_input' || type == 'idle_prompt') {
          s.status = ClaudeStatus.waitingInput;
          s.lastMessage = _clip(p['message'] as String?, 70) ?? s.lastMessage;
        }
      case 'Stop':
        _reconcile(s, p['background_tasks']);
        s.status = ClaudeStatus.idle;
        s.activeTool = null;
        s.toolStartedAt = null;
        final closing = p['last_assistant_message'] as String?;
        s.lastMessage = _clip(closing, 90) ?? s.lastMessage;
        if (closing != null && closing.trim().isNotEmpty) s.lastMessageFull = closing.trim();
      case 'SessionEnd':
        // `resume` and `clear` fire this too, and they are transitions, not
        // deaths: a session resumed from here reports SessionEnd on the way in
        // and keeps running. Treating every SessionEnd as terminal is what
        // made live panels read "encerrada" seconds after opening.
        final reason = (p['end_reason'] as String?) ?? 'other';
        s.status = (reason == 'resume' || reason == 'clear')
            ? ClaudeStatus.ready
            : ClaudeStatus.ended;
    }
  }

  /// One event fired from inside a fork, applied to that fork's row.
  ///
  /// The panel's own status is deliberately untouched here: while a subagent
  /// greps, the session that spawned it is waiting, not grepping.
  static void _subagent(HookState s, String id, String event, Map<String, dynamic> p) {
    // Only the four events below say something about a fork. Anything else
    // that happens to carry an `agent_id` -- a notification, an event added
    // in a later release -- used to conjure a row here with nothing in it to
    // show, which is where the nameless "· 0s" lines came from.
    const handled = {'SubagentStart', 'SubagentStop', 'PreToolUse', 'PostToolUse'};
    if (!handled.contains(event)) return;

    final agent = s.subagents.putIfAbsent(
      id,
      () => SubagentState(agentId: id, agentType: (p['agent_type'] as String?) ?? ''),
    );
    final type = p['agent_type'] as String?;
    if (type != null && type.isNotEmpty) agent.agentType = type;

    switch (event) {
      case 'SubagentStart':
        _claim(s, agent);
      case 'PreToolUse':
        agent.tools++;
        s.tools++;
        agent.status = ClaudeStatus.tool;
        agent.activeTool = p['tool_name'] as String?;
        agent.toolStartedAt = DateTime.now();
        agent.lastToolTarget = _target(p['tool_input']);
        final target = agent.lastToolTarget;
        agent.note('${agent.activeTool ?? '?'}${target == null ? '' : '($target)'}');
      case 'PostToolUse':
        agent.status = ClaudeStatus.working;
        agent.activeTool = null;
        agent.toolStartedAt = null;
        // Whoever held the pen, the file is what this session produced. A
        // panel whose forks did all the writing would otherwise show nothing.
        _touch(s, p);
      case 'SubagentStop':
        _finish(agent);
        final closing = p['last_assistant_message'] as String?;
        agent.lastMessage = _clip(closing, 90) ?? agent.lastMessage;
        if (closing != null && closing.trim().isNotEmpty) {
          agent.lastMessageFull = closing.trim();
        }
    }
  }

  /// The tool that asks instead of acting. Named once, because three places
  /// have to agree on it for a question not to read as a permission prompt.
  static const _askTool = 'AskUserQuestion';

  /// Record what an `AskUserQuestion` is asking, so the row can name the
  /// decision instead of the tool.
  ///
  /// The header is preferred over the question: it is written to be a chip
  /// ("Receitas"), which is what a 200px subtitle can hold, where the
  /// question is a full sentence that would be cut mid-word.
  static void _asked(HookState s, Object? input) {
    if (input is! Map) return;
    final asked = input['questions'];
    if (asked is! List || asked.isEmpty) return;
    s.questions = asked.length;
    final first = asked.first;
    if (first is! Map) return;
    final header = _clip(first['header'] as String?, 24);
    s.question = header ?? _clip(first['question'] as String?, 60);
  }

  /// An `Agent` call went out. Its description is the only human-readable
  /// name the fork will ever have, and it arrives one event too early to be
  /// filed under an id.
  static void _agentQueued(HookState s, Object? input) {
    if (input is! Map) return;
    s.pendingAgents.add(PendingAgent(
      description: _clip(input['description'] as String?, 60) ?? '',
      agentType: (input['subagent_type'] as String?) ?? '',
      prompt: (input['prompt'] as String?)?.trim() ?? '',
      background: input['run_in_background'] == true,
    ));
  }

  /// Give a freshly started fork the description of the call that asked for
  /// it: the oldest queued one of its own type, or simply the oldest. Two
  /// forks of the same type started together are matched in the order they
  /// were launched, which is the order the events arrive in.
  static void _claim(HookState s, SubagentState agent) {
    if (s.pendingAgents.isEmpty) return;
    var i = s.pendingAgents.indexWhere((q) => q.agentType == agent.agentType);
    if (i < 0) i = 0;
    final pending = s.pendingAgents.removeAt(i);
    if (agent.description.isEmpty) agent.description = pending.description;
    if (agent.prompt.isEmpty) agent.prompt = pending.prompt;
    agent.background = pending.background;
  }

  /// The `Agent` tool call came back. This is the one event that names the
  /// `agent_id` and the description together, so it corrects whatever the
  /// ordering guess in [_claim] made -- and for a background agent it is the
  /// launch receipt (`async_launched`), not the result.
  ///
  /// A receipt for a fork nobody ever saw start only creates a row when it is
  /// that launch receipt, which carries the description. A *result* for an
  /// unknown id is nothing anyone could read -- no errand, no type, no time
  /// -- so it is dropped rather than drawn as an empty line.
  static void _agentReturned(HookState s, Map<String, dynamic> p) {
    final response = p['tool_response'];
    if (response is! Map) return;
    final id = response['agentId'] as String?;
    if (id == null || id.isEmpty) return;

    final launched = response['status'] == 'async_launched';
    var agent = s.subagents[id];
    if (agent == null) {
      if (!launched) return;
      agent = SubagentState(
        agentId: id,
        agentType: (response['agentType'] as String?) ?? '',
      );
      s.subagents[id] = agent;
    }

    final input = p['tool_input'];
    if (input is Map) {
      final described = _clip(input['description'] as String?, 60);
      if (described != null) agent.description = described;
      final prompt = (input['prompt'] as String?)?.trim();
      if (prompt != null && prompt.isNotEmpty) agent.prompt = prompt;
      final type = input['subagent_type'] as String?;
      if (agent.agentType.isEmpty && type != null) agent.agentType = type;
      agent.background = input['run_in_background'] == true;
    }
    if (launched) {
      agent.background = true;
      return;
    }

    // A zero duration is the tool saying it does not know, not a fork that
    // ran for no time. Left null, the row times itself instead.
    final ms = (response['totalDurationMs'] as num?)?.toInt();
    if (ms != null && ms > 0) agent.durationMs = ms;
    final tokens = (response['totalTokens'] as num?)?.toInt();
    if (tokens != null && tokens > 0) agent.tokens = tokens;
    _finish(agent);
  }

  /// What `Stop` says is still in flight. A session that goes back to the
  /// prompt with background agents out reports them here, which is how a
  /// panel knows the difference between "acabou" and "largou rodando".
  static void _reconcile(HookState s, Object? tasks) {
    // A pending call with no `SubagentStart` was denied or never spawned;
    // carrying it to the next turn would misname the next fork.
    s.pendingAgents.clear();
    if (tasks is! List) return;
    final live = <String>{};
    for (final task in tasks) {
      if (task is! Map) continue;
      if (task['type'] != 'subagent') continue;
      final id = task['id'] as String?;
      if (id == null || id.isEmpty) continue;
      live.add(id);
      final described = _clip(task['description'] as String?, 60);
      final named = (task['agent_type'] as String?) ?? '';
      // A task the session cannot name is not something the sidebar can
      // draw: a row with no errand and no type is a blank line with a tick.
      if (!s.subagents.containsKey(id) && described == null && named.isEmpty) continue;

      final agent = s.subagents.putIfAbsent(
        id,
        () => SubagentState(agentId: id, agentType: (task['agent_type'] as String?) ?? ''),
      );
      if (named.isNotEmpty) agent.agentType = named;
      agent.background = true;
      if (agent.description.isEmpty && described != null) agent.description = described;
    }
    // Anything we still think is running but the session no longer lists is
    // one whose `SubagentStop` never landed -- a dropped hook, a killed fork.
    for (final agent in s.subagents.values) {
      if (agent.running && agent.background && !live.contains(agent.agentId)) _finish(agent);
    }
  }

  static void _finish(SubagentState agent) {
    if (!agent.running) return;
    agent.endedAt = DateTime.now();
    agent.status = ClaudeStatus.idle;
    agent.activeTool = null;
    agent.toolStartedAt = null;
  }

  /// Record a file the session just changed. See [HookState.touched].
  ///
  /// Only the four tools that write, and only on `PostToolUse`: `PreToolUse`
  /// announces a call that may still be denied, so a panel that recorded there
  /// would list files the session never got to touch. `Bash` is left out on
  /// purpose -- knowing what a command line wrote means interpreting it, and a
  /// guess in this list is worse than an omission, because the list is read as
  /// the answer to "what did it do".
  static void _touch(HookState s, Map<String, dynamic> p) {
    const writes = {
      'Write': 'file_path',
      'Edit': 'file_path',
      'MultiEdit': 'file_path',
      'NotebookEdit': 'notebook_path',
    };
    final key = writes[(p['tool_name'] as String?) ?? ''];
    if (key == null) return;
    final input = p['tool_input'];
    if (input is! Map) return;
    final raw = input[key];
    if (raw is! String || raw.isEmpty) return;

    final path = _absolute(raw, p['cwd'] as String?);
    // Order is first touch, not last: a list that reshuffled itself every time
    // the agent came back to a file would be unreadable while it worked.
    if (s.touched.contains(path)) return;
    s.touched.add(path);
    if (s.touched.length > HookState.maxTouched) s.touched.removeAt(0);
  }

  /// Every hook payload carries the session's `cwd`, so a tool called with a
  /// relative path still ends up as something the Finder can open.
  static String _absolute(String path, String? cwd) {
    if (path.startsWith('/')) return path;
    if (cwd == null || cwd.isEmpty) return path;
    final rel = path.startsWith('./') ? path.substring(2) : path;
    final base = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
    return '$base/$rel';
  }

  /// What the tool is acting on: a basename beats a full path in a 200px panel.
  static String? _target(Object? input) {
    if (input is! Map) return null;
    for (final key in ['file_path', 'path', 'notebook_path', 'pattern']) {
      final v = input[key];
      if (v is String && v.isNotEmpty) return v.split('/').last;
    }
    final cmd = input['command'];
    if (cmd is String && cmd.isNotEmpty) return _clip(cmd, 28);
    return null;
  }

  static String? _clip(String? text, int max) {
    if (text == null) return null;
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.isEmpty) return null;
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }
}
