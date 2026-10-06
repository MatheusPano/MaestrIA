import '../models.dart';

/// Como uma sugestão saiu da fila, pra quem tentar retirá-la depois.
enum SuggestionEnd { started, dismissed }

/// O que o [TaskMcp] precisa do resto do app: guardar uma sugestão no painel
/// e tirá-la de lá. Quem implementa é o store.
abstract interface class TaskDesk {
  /// Guarda a sugestão no painel [tabId]. Null quando o painel não existe
  /// mais -- uma sessão que sobreviveu ao fechamento dele.
  SuggestionQueued? suggest(
    String tabId, {
    required String title,
    required String tldr,
    required String prompt,
  });

  /// Retira a sugestão [taskId]. Quando ela não estava pendente, `already`
  /// diz por qual porta ela saiu -- e null nos dois é "nunca esteve aqui".
  ({bool withdrawn, SuggestionEnd? already}) withdraw(String tabId, String taskId);
}

/// O que a fila respondeu a um [TaskDesk.suggest].
class SuggestionQueued {
  SuggestionQueued(this.task, {required this.pending, this.evicted = const []});
  final SuggestedTask task;

  /// O que está pendente agora, contando a nova.
  final List<SuggestedTask> pending;

  /// As mais velhas que saíram pra caber esta. Ver [HookState.maxSuggestions].
  final List<SuggestedTask> evicted;
}

/// O servidor MCP que dá às sessões da Maestria o "tarefa sugerida" do Desktop.
///
/// O Claude Desktop injeta nas sessões que abre um servidor MCP próprio, com um
/// `spawn_task` que vira um cartão no chat; o CLI não tem nada disso, e um hook
/// não ajuda -- hook observa ferramenta, não cria uma. Então a Maestria serve a
/// sua, no mesmo [HookServer] que já recebe os hooks: cada sessão sobe com um
/// `--mcp-config` que aponta pra `/mcp/<tabId>`, e o painel é quem guarda o
/// cartão.
///
/// Só o pedaço do protocolo que uma ferramenta precisa: o transporte HTTP
/// "streamable" respondendo JSON (sem SSE), `initialize`, `tools/list` e
/// `tools/call`. Puro de propósito: é JSON-RPC entrando e saindo, e é o pedaço
/// que vale testar.
class TaskMcp {
  /// O nome do servidor no `--mcp-config`, que é o meio do nome das
  /// ferramentas: `mcp__maestria__suggest_task`.
  static const server = 'maestria';
  static const suggestTool = 'suggest_task';
  static const dismissTool = 'dismiss_task';

  /// Os nomes como a sessão os vê, que é como a permissão os pede.
  static List<String> get toolNames => [
    'mcp__${server}__$suggestTool',
    'mcp__${server}__$dismissTool',
  ];

  /// O teto do prompt, o mesmo do Desktop: a sessão nova lê o código sozinha.
  static const maxPrompt = 32000;

  /// A versão do protocolo que este servidor fala quando o cliente não diz a
  /// dele. Quando diz, ecoa: o que se usa aqui não mudou entre as versões.
  static const protocolVersion = '2025-06-18';

  /// Responde a um corpo de POST. Null quando não há o que responder -- uma
  /// notificação, ou um lote só delas --, que no HTTP vira um `202`.
  static Object? handle(Object? body, String tabId, TaskDesk desk) {
    if (body is List) {
      final answers = body.map((m) => _one(m, tabId, desk)).nonNulls.toList();
      return answers.isEmpty ? null : answers;
    }
    return _one(body, tabId, desk);
  }

  /// A resposta a um corpo que nem JSON era.
  static Map<String, dynamic> parseError() => _error(null, -32700, 'parse error');

  static Map<String, dynamic>? _one(Object? message, String tabId, TaskDesk desk) {
    if (message is! Map) return _error(null, -32600, 'invalid request');
    final id = message['id'];
    final method = message['method'];
    // Sem id é notificação (`notifications/initialized` e cia.), e sem método
    // é a resposta a algo que este servidor nunca perguntou: nada a dizer.
    if (id == null || method is! String) return null;
    final params = message['params'] is Map ? message['params'] as Map : const {};

    return switch (method) {
      'initialize' => _result(id, {
        'protocolVersion': (params['protocolVersion'] as String?) ?? protocolVersion,
        'capabilities': {
          'tools': {'listChanged': false},
        },
        'serverInfo': {'name': server, 'version': '1.0.0'},
        'instructions': _instructions,
      }),
      'ping' => _result(id, const {}),
      'tools/list' => _result(id, {'tools': _tools}),
      'tools/call' => _call(id, params, tabId, desk),
      _ => _error(id, -32601, 'method not found: $method'),
    };
  }

  static Map<String, dynamic> _call(Object id, Map params, String tabId, TaskDesk desk) {
    final name = params['name'];
    final args = params['arguments'] is Map ? params['arguments'] as Map : const {};
    return switch (name) {
      suggestTool => _result(id, _suggest(args, tabId, desk)),
      dismissTool => _result(id, _dismiss(args, tabId, desk)),
      _ => _error(id, -32602, 'unknown tool: $name'),
    };
  }

  static Map<String, dynamic> _suggest(Map args, String tabId, TaskDesk desk) {
    final prompt = _text(args['prompt']);
    if (prompt.isEmpty) return _toolError('prompt is required and cannot be empty.');
    if (prompt.length > maxPrompt) {
      return _toolError(
        'prompt is too long (${prompt.length} chars; max $maxPrompt). Trim it to the '
        'essentials; the new session can read the files itself.',
      );
    }
    final title = _clip(_text(args['title']), 200);
    final tldr = _clip(_text(args['tldr']), 2000);
    final queued = desk.suggest(tabId, title: title, tldr: tldr, prompt: prompt);
    if (queued == null) {
      return _toolError(
        'This session is no longer attached to a Maestria panel, so there is nowhere to '
        'show the suggestion. Mention it in your reply instead.',
      );
    }
    final dropped = queued.evicted.isEmpty
        ? ''
        : 'Pending suggestions are capped at ${HookState.maxSuggestions}, so the oldest '
              '${queued.evicted.length == 1 ? 'one was' : '${queued.evicted.length} were'} '
              'dropped: ${_list(queued.evicted)}. ';
    return _toolText(
      'Noted (${queued.task.id}). A card is showing in the Maestria panel for this session: '
      'the user can start it in a new session, in a fresh worktree or in their checkout, '
      'send it to this session, or dismiss it. If it becomes stale or superseded, call '
      '$dismissTool with this task_id. $dropped'
      'Currently pending: ${_list(queued.pending)}. Continue your current work.',
    );
  }

  static Map<String, dynamic> _dismiss(Map args, String tabId, TaskDesk desk) {
    final taskId = _text(args['task_id']);
    if (!_taskId.hasMatch(taskId)) {
      return _toolError('task_id must be the id returned by $suggestTool (format: task_xxxxxxxx).');
    }
    final out = desk.withdraw(tabId, taskId);
    if (out.withdrawn) {
      return _toolText(
        'Task $taskId withdrawn. The card is no longer shown. Continue your current work.',
      );
    }
    return _toolText(switch (out.already) {
      SuggestionEnd.started =>
        'Task $taskId was already started by the user, so it is no longer pending and '
            'cannot be withdrawn. Nothing was changed.',
      SuggestionEnd.dismissed => 'Task $taskId was already dismissed. Nothing was changed.',
      null =>
        'No pending task with id $taskId: it was never queued from this panel, or the panel '
            'was closed. Do not re-flag it. Nothing was changed.',
    });
  }

  static final _taskId = RegExp(r'^task_[0-9a-f]{8}$');

  /// O que a sessão lê no prompt de sistema, junto das instruções dos outros
  /// servidores MCP. Curto: o detalhe está na descrição da ferramenta.
  static const _instructions =
      'This session runs inside Maestria, a desktop cockpit for Claude Code sessions. '
      'When you notice work that deserves doing but is outside the scope of the current '
      'task, call $suggestTool instead of widening the task or only mentioning it in prose: '
      'the user gets a card they can start as a separate session with one click.';

  static const _suggestDescription =
      'Suggest a separate task for something you noticed that is outside the scope of your '
      'current work.\n\n'
      'Call this when you come across something that deserves fixing but does not belong in '
      'this change: dead code, stale docs, a missing test, a confirmed TODO, a bug or security '
      'issue spotted in passing. Do not use it for trivial fixes you can make inline, for '
      'anything the user asked you to do, for vague impressions or unverified hunches, or to '
      'split off parts of your own task. The call only queues a suggestion and returns; carry '
      'on with your current work.\n\n'
      'The user sees a "tarefa sugerida" card in the Maestria panel of this session, with your '
      'title and tldr, can read the full prompt, and with one click starts it as a new Claude '
      'Code session (in a fresh git worktree, or in their checkout of this repository), sends '
      'it to this session, or dismisses it. A new session starts from your prompt alone, on a '
      'checkout that may not have this session\'s changes, so the prompt has to stand alone: '
      'what to change and why, the files involved by repository-relative path, and any context '
      'from this conversation it depends on. If the find involves a secret or credential, say '
      'where it is rather than copying the value, since the prompt is stored and displayed.\n\n'
      'The result carries a task_id; if the suggestion later becomes moot, withdraw it with '
      '$dismissTool.';

  static const _dismissDescription =
      'Withdraw a task suggestion you queued earlier with $suggestTool.\n\n'
      'Call this when a suggestion has gone stale: the issue was fixed in this session (by you '
      'or the user), it turned out not to be a problem, or you have queued a better-scoped '
      'replacement (queue the replacement first, then dismiss the old task_id).\n\n'
      'Only a suggestion the user has not acted on can be withdrawn. If they already started or '
      'dismissed it, the result says so and nothing changes; that answer is final, so do not '
      'retry or re-flag it.';

  static final _tools = [
    {
      'name': suggestTool,
      'title': 'Suggest a task',
      'description': _suggestDescription,
      'inputSchema': {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description':
                'The card heading and the new session\'s name: a short imperative phrase '
                'starting with a verb, under 60 characters, that makes sense on its own, '
                'e.g. "Fix stale README badge".',
          },
          'tldr': {
            'type': 'string',
            'description':
                'One or two plain sentences on what the task would do and why it is worth '
                'doing. Shown on the card under the title, so no file paths or code.',
          },
          'prompt': {
            'type': 'string',
            'description':
                'The opening message of the new session: the goal, the files involved by '
                'repository-relative path, the context it needs from this conversation, and '
                'what done looks like. Markdown is fine. Hard limit $maxPrompt characters.',
          },
        },
        'required': ['title', 'tldr', 'prompt'],
      },
    },
    {
      'name': dismissTool,
      'title': 'Withdraw a suggested task',
      'description': _dismissDescription,
      'inputSchema': {
        'type': 'object',
        'properties': {
          'task_id': {
            'type': 'string',
            'description': 'The task_id from the $suggestTool result (task_1a2b3c4d).',
          },
          'reason': {
            'type': 'string',
            'description':
                'Optional short note on why the suggestion is no longer needed. It does not '
                'change the outcome.',
          },
        },
        'required': ['task_id'],
      },
    },
  ];

  static String _text(Object? v) => v is String ? v.trim() : '';

  static String _clip(String v, int max) => v.length <= max ? v : v.substring(0, max);

  static String _list(List<SuggestedTask> tasks) => tasks.isEmpty
      ? 'none'
      : tasks.map((t) => t.title.isEmpty ? t.id : '${t.id} "${t.title}"').join(', ');

  static Map<String, dynamic> _toolText(String text) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
  };

  static Map<String, dynamic> _toolError(String text) => {..._toolText(text), 'isError': true};

  static Map<String, dynamic> _result(Object id, Object result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  static Map<String, dynamic> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };
}
