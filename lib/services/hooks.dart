import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'docs.dart';
import 'paths.dart';

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

  /// Onde a porta desta janela fica anotada de uma execução pra outra.
  ///
  /// Ver [_bind]: é um arquivo com um número e nada mais, então não vale um
  /// json -- e ele é uma dica, não um estado. Perdê-lo custa uma porta nova.
  static File get portFile => File('$mxStateDir/hook-port');

  Future<void> start() async {
    if (_server != null) return;
    final server = await _bind();
    _server = server;
    _remember(server.port);
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

  /// Sobe na mesma porta da execução passada, quando ela estiver livre.
  ///
  /// A porta não é um detalhe interno: ela vai *escrita* dentro do
  /// `--settings` de cada sessão (ver [settingsFor]), e o que está no
  /// lançamento é o que vale pelo resto da vida daquela sessão -- o Claude
  /// Code guarda esses flags no roster do daemon dele e respawna a sessão com
  /// eles iguais. Com uma porta efêmera a cada `bind(..., 0)`, bastava fechar
  /// e reabrir a Maestria pra toda sessão sobrevivente ficar fazendo POST num
  /// número que não escuta mais: `hook error: connect ECONNREFUSED` a cada
  /// evento, duas vezes por tool call, sem nada que se pudesse editar depois
  /// (mexer no `settings.json` não alcança o que veio por `--settings`).
  ///
  /// Daí a preferência pela porta anotada. Se ela estiver ocupada -- outra
  /// janela da Maestria de pé, ou um processo qualquer que a tomou --, pega
  /// uma efêmera e passa a anotar essa: sessão nova nasce apontando pra porta
  /// certa de qualquer jeito, e a próxima execução tenta a última que
  /// funcionou em vez de insistir num número que talvez nunca mais vague.
  Future<HttpServer> _bind() async {
    if (_saved() case final preferred?) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, preferred);
      } on SocketException {
        // Ocupada. A efêmera abaixo é o plano B.
      }
    }
    return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }

  /// A porta anotada, se houver uma que ainda faça sentido pedir.
  int? _saved() {
    try {
      final port = int.tryParse(portFile.readAsStringSync().trim());
      // `0` é "me dê qualquer uma", e uma porta privilegiada este processo não
      // teria como abrir: nos dois casos é o mesmo que não haver anotação.
      return (port != null && port > 1024 && port < 65536) ? port : null;
    } on FileSystemException {
      return null;
    }
  }

  void _remember(int port) {
    if (_saved() == port) return;
    try {
      portFile.parent.createSync(recursive: true);
      portFile.writeAsStringSync('$port\n');
    } on FileSystemException {
      // Sem anotação a próxima execução volta a sortear uma porta -- o bug de
      // sempre, e nada pior que ele. Não é motivo pra não abrir a janela.
    }
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
        'Notification': [group()],
        'Stop': [group()],
        // O fim de um fork. É o único aviso de que um agente disparado em
        // segundo plano terminou -- ver [HookState.forksOut] --, e sem ele
        // "quando terminar" só sabe que o *turno* acabou.
        'SubagentStop': [group()],
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
    // apart. What a fork did is the session's work and counts here; what it is
    // *doing* is not the session's status. Without this branch the row read
    // "rodando Grep(store.dart)" while the session itself was parked on the
    // `Agent` call that spawned it.
    final fork = p['agent_id'];
    if (fork is String && fork.isNotEmpty) {
      // Um fork que reporta é um fork vivo -- e às vezes um que não se viu
      // nascer, porque nem toda chamada que abre um agente passa pelo
      // `PreToolUse` desta sessão. A contagem observada manda na estimada.
      if (event == _forkEnd) {
        _forkDone(s, fork);
      } else if (s.forkIds.add(fork) && s.forkIds.length > s.forksOut) {
        s.forksOut = s.forkIds.length;
      }
      if (event == 'PreToolUse') s.tools++;
      // Whoever held the pen, the file is what this session produced. A panel
      // whose forks did all the writing would otherwise show nothing.
      if (event == 'PostToolUse') _touch(s, p);
      return;
    }
    // Um fim de fork sem carimbo: não dá pra saber qual, mas dá pra saber que
    // é um a menos.
    if (event == _forkEnd) {
      _forkDone(s, null);
      return;
    }

    switch (event) {
      case 'SessionStart':
        // Kept for the day it starts arriving: Claude Code does not fire this
        // one at an `http` hook today, which is why a panel settles itself.
        s.status = ClaudeStatus.ready;
        _forksClear(s);
      case 'UserPromptSubmit':
        // Answering a question submits a prompt, and so does abandoning it:
        // either way what was asked is no longer pending.
        s.question = null;
        s.questions = 0;
        s.prompts++;
        s.status = ClaudeStatus.working;
        s.lastPrompt = _clip(p['user_input'] as String?, 70);
      case 'PreToolUse':
        if (p['tool_name'] == _askTool) _asked(s, p['tool_input']);
        // Um agente disparado daqui pode sobreviver ao turno que o disparou:
        // ver [HookState.forksOut].
        if (_forkTools.contains(p['tool_name'])) s.forksOut++;
        // No `PreToolUse` e não no `PostToolUse`: o `ExitPlanMode` só volta se
        // o plano for aprovado, e um plano recusado é exatamente o que se quer
        // reler pra dizer por que. O texto é o mesmo nos dois lados.
        if (p['tool_name'] == _planTool) _planned(s, p['tool_input']);
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
        // Os forks eram do processo que acabou de sair de cena, em qualquer
        // dos dois casos: nenhum deles vai mandar o `SubagentStop` que
        // zeraria a conta, e uma conta que não zera trava a fila.
        _forksClear(s);
    }
  }

  /// As duas ferramentas que abrem um agente. `Task` é o nome antigo e `Agent`
  /// o de hoje; os dois aparecem, dependendo da versão do CLI da sessão.
  static const _forkTools = {'Task', 'Agent'};

  /// O evento com que um fork se despede.
  static const _forkEnd = 'SubagentStop';

  /// Um fork a menos. O piso em zero importa: um `SubagentStop` a mais que as
  /// chamadas vistas -- um fork de fork, uma sessão retomada no meio -- não
  /// pode deixar a conta negativa, porque negativa ela nunca mais fecha.
  static void _forkDone(HookState s, String? id) {
    if (id != null) s.forkIds.remove(id);
    if (s.forksOut > 0) s.forksOut--;
  }

  static void _forksClear(HookState s) {
    s.forkIds.clear();
    s.forksOut = 0;
  }

  /// A ferramenta que entrega um plano. O `tool_input` dela é `{plan: "..."}`,
  /// e esse markdown é a única cópia que existe do plano fora do scrollback.
  static const _planTool = 'ExitPlanMode';

  /// Guarda o plano que a sessão acabou de apresentar. Ver [HookState.plans].
  static void _planned(HookState s, Object? input) {
    if (input is! Map) return;
    final text = input['plan'];
    if (text is! String || text.trim().isEmpty) return;
    // Reapresentar o mesmo plano -- o que acontece quando você recusa, comenta
    // e a sessão volta com ele igual -- não é um plano novo.
    if (s.plans.isNotEmpty && s.plans.last.text == text) return;
    s.plans.add(PlanNote(text: text));
    if (s.plans.length > HookState.maxPlans) s.plans.removeAt(0);
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

  /// Record a file the session just changed. See [HookState.touched].
  ///
  /// The four tools that write, and only on `PostToolUse`: `PreToolUse`
  /// announces a call that may still be denied, so a panel that recorded there
  /// would list files the session never got to touch.
  ///
  /// `Bash` counts only for markdown, and only where the command says the path
  /// out loud -- ver [_shellMarkdown]. Interpretar uma linha de comando é
  /// adivinhar, e um chute nesta lista é pior que uma omissão, porque ela é
  /// lida como a resposta de "o que essa sessão fez". A exceção existe porque
  /// documento é justamente o que se escreve com `cat > x.md <<'EOF'`: sem
  /// isso, a fita de documentos de uma sessão que trabalha pelo shell fica
  /// vazia -- o que é o mesmo que não existir.
  static void _touch(HookState s, Map<String, dynamic> p) {
    const writes = {
      'Write': 'file_path',
      'Edit': 'file_path',
      'MultiEdit': 'file_path',
      'NotebookEdit': 'notebook_path',
    };
    final tool = (p['tool_name'] as String?) ?? '';
    final input = p['tool_input'];
    if (input is! Map) return;
    final cwd = p['cwd'] as String?;

    if (tool == 'Bash') {
      final command = input['command'];
      if (command is! String) return;
      for (final found in _shellMarkdown(command)) {
        _remember(s, _absolute(found, cwd));
      }
      return;
    }

    final key = writes[tool];
    if (key == null) return;
    final raw = input[key];
    if (raw is! String || raw.isEmpty) return;
    _remember(s, _absolute(raw, cwd));
  }

  static void _remember(HookState s, String path) {
    // Order is first touch, not last: a list that reshuffled itself every time
    // the agent came back to a file would be unreadable while it worked.
    if (s.touched.contains(path)) return;
    s.touched.add(path);
    if (s.touched.length > HookState.maxTouched) s.touched.removeAt(0);
  }

  /// Os markdown que uma linha de comando acabou de escrever.
  ///
  /// Só as quatro formas em que o caminho está escrito no comando e não sobra
  /// nada pra interpretar: o alvo de uma redireção (`>`, `>>`), os arquivos de
  /// um `tee`, os de um `sed -i`, e o destino de um `cp`/`mv`/`install`. Um
  /// script que escolhe o nome do arquivo sozinho não deixa nada pra ler, e
  /// ali a omissão continua valendo mais que o palpite.
  ///
  /// Caminho com `$`, `~` sem HOME, ou glob fica fora: o que entra nesta lista
  /// vai virar uma ficha clicável e um `Quick Look`, e um caminho que só o
  /// shell sabe resolver abriria em nada.
  static List<String> _shellMarkdown(String command) {
    final found = <String>[];
    void keep(String? token) {
      final path = _plainPath(token);
      if (path == null || !isMarkdownPath(path)) return;
      if (!found.contains(path)) found.add(path);
    }

    for (final segment in _commands(command).split(RegExp(r'[|;\n]|&&'))) {
      for (final m in _redirect.allMatches(segment)) {
        keep(m.group(1) ?? m.group(2) ?? m.group(3));
      }

      final words = segment.trim().split(RegExp(r'\s+'));
      // `FOO=1 tee ...`: a atribuição na frente não é o comando.
      final head = words.indexWhere((w) => !RegExp(r'^\w+=').hasMatch(w));
      if (head < 0) continue;
      final verb = words[head].split('/').last;
      final args = words.skip(head + 1);
      final flags = args.where((w) => w.startsWith('-'));
      final operands = args.where((w) => !w.startsWith('-')).toList();

      switch (verb) {
        // Todo operando é um arquivo que acabou de ser escrito.
        case 'tee':
          operands.forEach(keep);
        case 'sed' when flags.any((f) => f.startsWith('-i') || f == '--in-place'):
          // O primeiro operando de um `sed` é o script (`s/a/b/`) quando não
          // veio por `-e`; ele não é markdown, então [keep] o descarta sozinho.
          operands.forEach(keep);
        // Só o destino: a origem é um arquivo que ninguém mexeu.
        case 'cp' || 'mv' || 'install':
          keep(operands.lastOrNull);
      }
    }
    return found;
  }

  /// O comando sem o corpo dos heredocs.
  ///
  /// O corpo é texto, não comando -- e texto de markdown, que é cheio de
  /// linhas de citação começando em `>`. Sem tirá-lo, um `cat > nota.md` com
  /// uma citação `> veja o roteiro.md` dentro registraria um "roteiro.md" que
  /// nunca existiu.
  static String _commands(String command) {
    final lines = <String>[];
    String? delimiter;
    for (final line in command.split('\n')) {
      if (delimiter != null) {
        if (line.trim() == delimiter) delimiter = null;
        continue;
      }
      lines.add(line);
      final open = _heredoc.firstMatch(line);
      if (open != null) delimiter = open.group(1) ?? open.group(2) ?? open.group(3);
    }
    return lines.join('\n');
  }

  /// O alvo de uma redireção. `2>&1` não casa: `&` está fora do caminho.
  static final _redirect = RegExp(r'''\d?>>?\s*(?:'([^']+)'|"([^"]+)"|([^\s'"|;&<>()]+))''');

  static final _heredoc = RegExp(r'''<<-?\s*(?:'([^']+)'|"([^"]+)"|(\w+))''');

  /// O caminho de um token do shell, se ele for um caminho e não uma receita
  /// pra descobrir um: fora as aspas, e nada de variável ou glob.
  static String? _plainPath(String? token) {
    if (token == null) return null;
    var path = token.trim();
    if (path.length >= 2 && (path.startsWith("'") || path.startsWith('"'))) {
      final quote = path[0];
      if (path.endsWith(quote)) path = path.substring(1, path.length - 1);
    }
    if (path.isEmpty || path.contains(RegExp(r'[\$*?`]'))) return null;
    return path;
  }

  /// Every hook payload carries the session's `cwd`, so a tool called with a
  /// relative path still ends up as something the Finder can open.
  static String _absolute(String path, String? cwd) {
    if (path.startsWith('/')) return path;
    // Um `~` vindo de uma linha de comando: quem for abrir isto -- o Quick
    // Look, o leitor -- não expande nada, então quem expande é [expandHome].
    if (path == '~' || path.startsWith('~/')) return expandHome(path);
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
